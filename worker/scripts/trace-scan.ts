// Trace a real scan end-to-end without the Postgres queue or Gmail plumbing. Loads a JSON array of
// your own emails, runs the real graph against the real model, and (when LANGSMITH_TRACING=true)
// streams a full trace to your LangSmith project. This is a dev/testing tool — it uses your own
// inbox data and your own keys.
//
//   cp fixtures/my-inbox.example.json fixtures/my-inbox.json   # then fill with a few real emails
//   npm run trace                                              # or: npm run trace -- path/to.json
//
// Env: DEEPSEEK_API_KEY (required), LANGSMITH_TRACING=true + LANGSMITH_API_KEY (for tracing),
// optional CLASSIFIER_* and LANGSMITH_PROJECT.

import { readFileSync } from "node:fs";
import { MemorySaver } from "@langchain/langgraph";
import { buildGraph, type RouteOutcome } from "../src/graph/graph.ts";
import { createScanExecutor } from "../src/executor.ts";
import type { MailMetadata } from "../src/domain/email.ts";
import { makeChatFn, resolveClassifierConfig, resolveReasonerConfig } from "../src/llm/client.ts";
import { tracingEnabled, withTracing } from "../src/llm/trace.ts";

function loadMessages(path: string): MailMetadata[] {
  const parsed = JSON.parse(readFileSync(path, "utf8"));
  if (!Array.isArray(parsed)) throw new Error(`${path} must be a JSON array of messages`);
  return parsed.map((m, i) => ({
    id: String(m.id ?? `msg-${i}`),
    subject: String(m.subject ?? ""),
    sender: String(m.sender ?? ""),
    snippet: String(m.snippet ?? ""),
    received_at: String(m.received_at ?? new Date().toISOString()),
  }));
}

async function main(): Promise<void> {
  const path = process.argv[2] ?? "fixtures/my-inbox.json";
  const rawMessages = loadMessages(path);
  console.log(`Loaded ${rawMessages.length} messages from ${path}`);
  console.log(tracingEnabled() ? `Tracing ON → project "${process.env.LANGSMITH_PROJECT ?? "default"}"` : "Tracing OFF (set LANGSMITH_TRACING=true to record)");

  const reasoner = withTracing(makeChatFn(resolveReasonerConfig()), "reasoner");
  const classifierConfig = resolveClassifierConfig();
  const classifier = withTracing(
    classifierConfig ? makeChatFn(classifierConfig) : makeChatFn(resolveReasonerConfig()),
    "classifier",
  );

  const app = buildGraph(
    { chat: reasoner, classifierChat: classifier, executeTool: createScanExecutor(rawMessages) },
    new MemorySaver(),
  );
  const config = { configurable: { thread_id: `trace-${Date.now()}` } };

  console.log("\nScanning…\n");
  const final = await app.invoke({ rawMessages }, config);

  console.log("=== Outcomes ===");
  for (const outcome of (final.results ?? []) as RouteOutcome[]) {
    const a = outcome.assessment;
    const detail =
      outcome.kind === "near_miss"
        ? `(${outcome.reason})`
        : `${a.amount ?? "?"} ${a.currency ?? ""} ${a.billing_cycle ?? ""}`.trim();
    console.log(`  ${outcome.kind.padEnd(10)} ${a.merchant_name.padEnd(20)} ${detail}`);
  }

  console.log(tracingEnabled() ? "\nOpen https://smith.langchain.com to view the trace." : "");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
