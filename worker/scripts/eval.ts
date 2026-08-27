// Golden-set eval runner. Scores the CURRENT per-merchant pipeline (the baseline) and the NEW
// two-tier autonomous funnel against fixtures/golden-set.json using the real model, then reports
// whether the funnel meets or beats the baseline. This is the gate the migration plan requires
// before the old judgment code may be deleted.
//
//   cd worker && npm run eval            # needs DEEPSEEK_API_KEY in .env
//
// It writes the baseline report to fixtures/eval-baseline.json (task 1.3) and prints both reports.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { MemorySaver } from "@langchain/langgraph";
import { buildGraph, type RouteOutcome } from "../src/graph/graph.ts";
import { createScanExecutor } from "../src/executor.ts";
import type { MailMetadata } from "../src/domain/email.ts";
import { makeChatFn, resolveClassifierConfig, resolveReasonerConfig } from "../src/llm/client.ts";
import { inMemoryReconcileReaders } from "../src/agent/tools.ts";
import { runTwoTierScan } from "../src/agent/pipeline.ts";
import {
  loadGoldenCases,
  meetsOrBeats,
  scoreCases,
  type EvalReport,
  type Runner,
  type SurfacedCandidate,
} from "../src/eval/harness.ts";

function goldenPath(): string {
  return fileURLToPath(new URL("../fixtures/golden-set.json", import.meta.url));
}
function baselinePath(): string {
  return fileURLToPath(new URL("../fixtures/eval-baseline.json", import.meta.url));
}

const reasoner = makeChatFn(resolveReasonerConfig());
const classifierConfig = resolveClassifierConfig();
const classifier = classifierConfig ? makeChatFn(classifierConfig) : reasoner;

// Baseline: the existing per-merchant graph. A merchant is "surfaced" when it routes to present or
// clarify (a candidate shown to the user); near_miss is an abstain.
const baselineRunner: Runner = async (messages: MailMetadata[]) => {
  const app = buildGraph(
    { chat: reasoner, classifierChat: classifier, executeTool: createScanExecutor(messages) },
    new MemorySaver(),
  );
  const final = await app.invoke({ rawMessages: messages }, { configurable: { thread_id: `bl-${Date.now()}-${Math.random()}` } });
  const outcomes = (final.results ?? []) as RouteOutcome[];
  return outcomes
    .filter((o) => o.kind !== "near_miss")
    .map<SurfacedCandidate>((o) => ({ merchant_key: o.assessment.canonical_merchant_key, recurrence: o.assessment.recurrence }));
};

// Candidate: the new two-tier funnel. A merchant is "surfaced" when the agent proposes it.
const funnelRunner: Runner = async (messages: MailMetadata[]) => {
  const { proposals } = await runTwoTierScan(messages, {
    chat: reasoner,
    triageChat: classifier,
    reconcile: inMemoryReconcileReaders({}),
    threadId: `fn-${Date.now()}-${Math.random()}`,
  });
  return proposals.map<SurfacedCandidate>((p) => ({ merchant_key: p.merchant_key, recurrence: p.recurrence }));
};

function printReport(label: string, r: EvalReport): void {
  console.log(`\n=== ${label} ===`);
  console.log(`  recall              ${(r.recall * 100).toFixed(0)}%  (${r.truePositives}/${r.expectedSurface} real subs surfaced)`);
  console.log(`  false positives     ${r.falsePositives}  (one-offs/marketing wrongly surfaced)`);
  console.log(`  recurrence errors   ${r.recurrenceErrors}`);
  console.log(`  abstain clean       ${r.abstainClean ? "yes" : "NO"}`);
  for (const c of r.cases) {
    const flags = [
      c.falseNegatives.length ? `missed:${c.falseNegatives.join(",")}` : "",
      c.falsePositives.length ? `false+:${c.falsePositives.join(",")}` : "",
      c.recurrenceErrors.length ? `recur:${c.recurrenceErrors.join(",")}` : "",
    ].filter(Boolean).join(" ");
    console.log(`    ${flags ? "✗" : "✓"} ${c.id}${flags ? "  " + flags : ""}`);
  }
}

async function main(): Promise<void> {
  const cases = loadGoldenCases(JSON.parse(readFileSync(goldenPath(), "utf8")));
  console.log(`Scoring ${cases.length} golden cases with the real model…`);

  const baseline = await scoreCases(cases, baselineRunner);
  printReport("BASELINE — current per-merchant pipeline", baseline);
  writeFileSync(baselinePath(), JSON.stringify(baseline, null, 2));
  console.log(`\n(baseline written to fixtures/eval-baseline.json)`);

  const funnel = await scoreCases(cases, funnelRunner);
  printReport("CANDIDATE — two-tier autonomous funnel", funnel);

  const pass = meetsOrBeats(funnel, baseline);
  console.log(`\n=== GATE ===`);
  console.log(`  funnel meets or beats baseline: ${pass ? "PASS ✅" : "FAIL ❌"}`);
  console.log(`  (recall ${(funnel.recall * 100).toFixed(0)}% vs ${(baseline.recall * 100).toFixed(0)}%, ` +
    `false+ ${funnel.falsePositives} vs ${baseline.falsePositives}, ` +
    `recur-err ${funnel.recurrenceErrors} vs ${baseline.recurrenceErrors})`);
  if (!pass) process.exitCode = 1;
}

main().catch((error) => {
  console.error("[eval] failed:", error);
  process.exit(1);
});
