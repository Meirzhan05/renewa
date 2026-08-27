// Run the two-tier autonomous funnel against your REAL Gmail (OAuth, read-only), print what the
// agent decided per email, and save every processed email + its decision to one JSON file under out/
// (gitignored). Dev/testing tool — reads are read-only and proposals are printed/saved, never applied.
//
//   cp .env.example .env    # fill GMAIL_OAUTH_CLIENT_ID + _SECRET + DEEPSEEK_API_KEY
//   npm run gmail
//
// One-time Google setup:
//   1. console.cloud.google.com → create/select a project.
//   2. APIs & Services → Library → enable "Gmail API".
//   3. APIs & Services → OAuth consent screen → External → add yourself under "Test users".
//   4. APIs & Services → Credentials → Create credentials → OAuth client ID → type
//      "Web application" → under "Authorized redirect URIs" add EXACTLY:  http://127.0.0.1:42813
//      (match GMAIL_OAUTH_PORT). The script prints the exact URI it uses, so register that one.
//   5. Copy the Client ID + Client secret into .env.

import { writeFileSync } from "node:fs";
import { MemorySaver } from "@langchain/langgraph";
import type { MailMetadata } from "../src/domain/email.ts";
import { makeChatFn, resolveClassifierConfig, resolveReasonerConfig, type ChatMessage } from "../src/llm/client.ts";
import { buildAgentGraph } from "../src/agent/agent-graph.ts";
import { triageInbox } from "../src/agent/triage.ts";
import { inMemoryReconcileReaders } from "../src/agent/tools.ts";
import type { ProposalCandidate } from "../src/agent/types.ts";
import { authorize, createGmailReadExecutor, fetchInbox, loadGmailEnv, maskEmail, outDir } from "./gmail-client.ts";

// Ask the agent to narrate its reasoning (script-only; production/worker run without this).
const REASONING_SUFFIX =
  "Narrate your reasoning for a human reviewer: in the message content of EVERY turn — including " +
  "turns where you also call a tool, and your final message — write one or two plain sentences on " +
  "WHY you are taking that step or reaching that conclusion. Keep it short.";

function summarizeArgs(tool: string, argsJson: string): string {
  try {
    const a = JSON.parse(argsJson) as Record<string, unknown>;
    if (tool === "search_inbox") return `query="${String(a.query ?? "")}"`;
    if (tool === "fetch") return String(a.message_id ?? "");
    if (tool === "compute_cadence") return `${Array.isArray(a.message_ids) ? a.message_ids.length : 0} ids`;
    if (tool === "list_prior_decisions") return String(a.merchant ?? "");
    if (tool === "propose") return String(a.merchant_name ?? "");
    return "";
  } catch {
    return "";
  }
}

type ReasoningStep = { thought: string; action: string | null };

/** Pull the agent's turn-by-turn reasoning (assistant content) + the action it took each turn. */
function reasoningSteps(messages: ChatMessage[]): ReasoningStep[] {
  const steps: ReasoningStep[] = [];
  for (const m of messages) {
    if (m.role !== "assistant") continue;
    const thought = (m.content ?? "").trim();
    const action =
      m.tool_calls && m.tool_calls.length > 0
        ? m.tool_calls.map((c) => `${c.function.name}(${summarizeArgs(c.function.name, c.function.arguments)})`).join(", ")
        : null;
    if (thought || action) steps.push({ thought, action });
  }
  return steps;
}

async function main(): Promise<void> {
  const env = loadGmailEnv();
  const reasoner = makeChatFn(resolveReasonerConfig());
  const classifierConfig = resolveClassifierConfig();
  const classifier = classifierConfig ? makeChatFn(classifierConfig) : reasoner;

  console.log("Authorizing with the Gmail API (read-only)…");
  const auth = await authorize(env);
  const { address, emails } = await fetchInbox(auth, env);
  console.log(`Connected as ${maskEmail(address)}. Fetched ${emails.length} message(s) from the last ${env.sinceDays} days.\n`);
  if (emails.length === 0) {
    console.log("Nothing to scan. Widen GMAIL_SCAN_SINCE_DAYS.");
    return;
  }

  console.log("Tier 1 — triaging every email (look / skip)…");
  const { look, skip, degraded } = await triageInbox(emails, classifier);
  console.log(`  look ${look.length} · skip ${skip.length}${degraded ? " · (degraded: triage outage, admitted all)" : ""}\n`);

  console.log("Tier 2 — autonomous agent investigating and proposing…\n");
  const app = buildAgentGraph(
    {
      chat: reasoner,
      readExecutor: createGmailReadExecutor(auth, look),
      reconcile: inMemoryReconcileReaders({}),
      promptSuffix: REASONING_SUFFIX,
    },
    new MemorySaver(),
  );
  const final = await app.invoke({ rawMessages: look }, { configurable: { thread_id: `gmail-${Date.now()}` } });
  const proposals = (final.proposals ?? []) as ProposalCandidate[];
  const steps = reasoningSteps((final.messages ?? []) as ChatMessage[]);

  // Resolve what the agent DID with each email: "skipped_by_triage" (Tier-1 dropped it, never seen
  // by the agent), "proposed" (cited as evidence for a proposal), or "reviewed_no_proposal" (the
  // agent looked but decided it is not a subscription). Proposals cite message_ids in evidence_refs.
  const lookIds = new Set(look.map((m) => m.id));
  const proposalByEvidence = new Map<string, ProposalCandidate>();
  for (const p of proposals) for (const ref of p.evidence_refs) proposalByEvidence.set(ref, p);
  type Decision = "proposed" | "reviewed_no_proposal" | "skipped_by_triage";
  const decisionFor = (m: MailMetadata): { agent_decision: Decision; proposed_as: string | null } => {
    if (!lookIds.has(m.id)) return { agent_decision: "skipped_by_triage", proposed_as: null };
    const p = proposalByEvidence.get(m.id);
    if (p) return { agent_decision: "proposed", proposed_as: p.merchant_name };
    return { agent_decision: "reviewed_no_proposal", proposed_as: null };
  };
  const decided = emails.map((m) => ({ email: m, ...decisionFor(m) }));
  const proposedCount = decided.filter((d) => d.agent_decision === "proposed").length;
  const reviewedNo = decided.filter((d) => d.agent_decision === "reviewed_no_proposal").length;
  const skippedCount = decided.filter((d) => d.agent_decision === "skipped_by_triage").length;

  console.log(`=== Proposals (${proposals.length}) — the agent wants a human to confirm these ===`);
  if (proposals.length === 0) console.log("  (none)");
  for (const p of proposals) {
    const money = [p.amount ?? "?", p.currency ?? "", p.billing_cycle ?? ""].filter(Boolean).join(" ");
    console.log(
      `  • ${p.merchant_name.padEnd(24)} ${money.padEnd(18)} ${p.recurrence.padEnd(9)} ` +
        `conf ${p.confidence.toFixed(2)}  from [${p.evidence_refs.join(", ")}]`,
    );
  }

  console.log(
    `\n=== What the agent decided per email === ` +
      `(proposed ${proposedCount} · reviewed-no-proposal ${reviewedNo} · skipped-by-triage ${skippedCount})`,
  );
  const reviewed = decided.filter((d) => d.agent_decision !== "skipped_by_triage");
  for (const d of reviewed.slice(0, 50)) {
    const tag = d.agent_decision === "proposed" ? `→ PROPOSED: ${d.proposed_as}` : "→ no proposal";
    console.log(`  ${d.email.received_at.slice(0, 10)}  ${d.email.subject.slice(0, 50).padEnd(50)} ${tag}`);
  }
  if (reviewed.length > 50) console.log(`  … and ${reviewed.length - 50} more reviewed (full detail in the saved file)`);
  if (skippedCount > 0) console.log(`  (${skippedCount} skipped by Tier-1 triage — listed in the saved file)`);

  console.log(`\n=== Agent reasoning (what it was thinking, turn by turn) ===`);
  if (steps.length === 0) console.log("  (the model emitted no narration this run)");
  steps.forEach((s, i) => {
    console.log(`  ${i + 1}. ${s.thought || "(no narration)"}`);
    if (s.action) console.log(`       ↳ did: ${s.action}`);
  });

  const record = {
    generated_at: new Date().toISOString(),
    source: { user: maskEmail(address), limit: env.limit, since_days: env.sinceDays },
    counts: {
      fetched: emails.length,
      look: look.length,
      skip: skip.length,
      proposals: proposals.length,
      proposed_from_emails: proposedCount,
      reviewed_no_proposal: reviewedNo,
      skipped_by_triage: skippedCount,
      triage_degraded: degraded,
    },
    agent_reasoning: steps,
    proposals,
    emails: decided.map((d) => ({
      ...d.email,
      triage: lookIds.has(d.email.id) ? "look" : "skip",
      agent_decision: d.agent_decision,
      proposed_as: d.proposed_as,
    })),
  };
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const outPath = `${outDir()}gmail-processed-${stamp}.json`;
  writeFileSync(outPath, JSON.stringify(record, null, 2));
  console.log(`\nSaved ${emails.length} processed emails + per-email decisions to:\n  ${outPath}`);
}

main().catch((error) => {
  console.error("[gmail-scan] failed:", error instanceof Error ? error.message : error);
  process.exit(1);
});
