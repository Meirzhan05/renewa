// Show EXACTLY what inputs the Tier-2 agent receives when it works your real inbox: the seed it
// starts from, and every tool call it makes with the content that came back (search matches, the
// fetched email bodies, cadence numbers, reconcile lists, propose results). It runs the same Gmail
// fetch → triage → agent path as `npm run gmail`, then reconstructs the agent's message transcript —
// the `tool`-role messages ARE the fetched-email inputs. Read-only; nothing is written to the inbox.
//
//   npm run gmail:trace
//
// Uses the same .env + cached OAuth token as `npm run gmail`. Full transcript is saved under out/.

import { writeFileSync } from "node:fs";
import { MemorySaver } from "@langchain/langgraph";
import { makeChatFn, resolveClassifierConfig, resolveReasonerConfig, type ChatMessage } from "../src/llm/client.ts";
import { buildAgentGraph } from "../src/agent/agent-graph.ts";
import { triageInbox } from "../src/agent/triage.ts";
import { inMemoryReconcileReaders } from "../src/agent/tools.ts";
import { authorize, createGmailReadExecutor, fetchInbox, loadGmailEnv, maskEmail, outDir } from "./gmail-client.ts";

function safeParse(text: string | null | undefined): unknown {
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

/** One "the agent asked X, got Y back" step, paired by tool_call_id across the transcript. */
type Interaction = { step: number; tool: string; arguments: unknown; result: unknown };

function extractInteractions(messages: ChatMessage[]): Interaction[] {
  const requests = new Map<string, { tool: string; arguments: unknown }>();
  const interactions: Interaction[] = [];
  for (const m of messages) {
    if (m.role === "assistant" && m.tool_calls) {
      for (const c of m.tool_calls) {
        requests.set(c.id, { tool: c.function.name, arguments: safeParse(c.function.arguments) });
      }
    }
    if (m.role === "tool" && m.tool_call_id) {
      const req = requests.get(m.tool_call_id);
      interactions.push({
        step: interactions.length + 1,
        tool: req?.tool ?? m.name ?? "unknown",
        arguments: req?.arguments ?? null,
        result: safeParse(m.content),
      });
    }
  }
  return interactions;
}

function printResult(tool: string, result: unknown): void {
  const r = (result ?? {}) as Record<string, unknown>;
  if (tool === "search_inbox" || tool === "get_more") {
    const matches = (r.matches ?? []) as Array<{ message_id?: string; subject?: string }>;
    console.log(`      → ${matches.length} match(es):`);
    for (const m of matches.slice(0, 8)) console.log(`          [${m.message_id}] ${String(m.subject ?? "").slice(0, 60)}`);
    if (matches.length > 8) console.log(`          … +${matches.length - 8} more`);
  } else if (tool === "fetch") {
    const msg = r.message as { subject?: string; sender?: string; content?: string } | null;
    if (!msg) {
      console.log("      → (not found)");
    } else {
      console.log(`      → subject: ${String(msg.subject ?? "").slice(0, 70)}`);
      console.log(`        sender:  ${String(msg.sender ?? "").slice(0, 70)}`);
      console.log(`        content: ${String(msg.content ?? "").replace(/\s+/g, " ").slice(0, 200)}`);
    }
  } else if (tool === "compute_cadence") {
    const c = (r.cadence ?? {}) as Record<string, unknown>;
    console.log(`      → amounts ${JSON.stringify(c.amounts ?? [])} · spread ${c.relativeSpread ?? "?"} · median interval ${c.medianIntervalDays ?? "?"}d`);
  } else if (tool === "list_current_subscriptions") {
    const subs = (r.subscriptions ?? []) as unknown[];
    console.log(`      → ${subs.length} tracked subscription(s)`);
  } else if (tool === "list_prior_decisions") {
    const priors = (r.prior_decisions ?? []) as unknown[];
    console.log(`      → ${priors.length} prior decision(s)`);
  } else if (tool === "propose") {
    console.log(`      → ${r.accepted ? `accepted: ${r.merchant_key}` : `rejected: ${r.reason}`}`);
  } else {
    console.log(`      → ${JSON.stringify(result).slice(0, 200)}`);
  }
}

async function main(): Promise<void> {
  const env = loadGmailEnv();
  const reasoner = makeChatFn(resolveReasonerConfig());
  const classifierConfig = resolveClassifierConfig();
  const classifier = classifierConfig ? makeChatFn(classifierConfig) : reasoner;

  console.log("Authorizing with the Gmail API (read-only)…");
  const auth = await authorize(env);
  const { address, emails } = await fetchInbox(auth, env);
  console.log(`Connected as ${maskEmail(address)}. Fetched ${emails.length} message(s).\n`);
  if (emails.length === 0) {
    console.log("Nothing to scan. Widen GMAIL_SCAN_SINCE_DAYS.");
    return;
  }

  const { look } = await triageInbox(emails, classifier);
  console.log(`Tier-1 admitted ${look.length} email(s) to the agent.\n`);

  const app = buildAgentGraph(
    { chat: reasoner, readExecutor: createGmailReadExecutor(auth, look), reconcile: inMemoryReconcileReaders({}) },
    new MemorySaver(),
  );
  const final = await app.invoke({ rawMessages: look }, { configurable: { thread_id: `trace-${Date.now()}` } });
  const messages = (final.messages ?? []) as ChatMessage[];

  // The seed: the first user message is the JSON the agent starts from (look_set + reconcile context).
  const seedMessage = messages.find((m) => m.role === "user");
  const seed = safeParse(seedMessage?.content) as {
    look_set?: unknown[];
    current_subscriptions?: unknown[];
    prior_decisions?: unknown[];
  } | null;

  console.log("=== SEED INPUT — what the agent receives before any tool call ===");
  console.log(`  look_set: ${seed?.look_set?.length ?? 0} emails (subject/sender/snippet/date per email)`);
  console.log(`  current_subscriptions: ${seed?.current_subscriptions?.length ?? 0}`);
  console.log(`  prior_decisions: ${seed?.prior_decisions?.length ?? 0}`);
  for (const e of (seed?.look_set ?? []).slice(0, 5) as Array<Record<string, unknown>>) {
    console.log(`    · [${e.message_id}] ${String(e.subject ?? "").slice(0, 60)}`);
  }
  if ((seed?.look_set?.length ?? 0) > 5) console.log(`    … +${(seed!.look_set!.length as number) - 5} more (full list in the saved file)`);

  const interactions = extractInteractions(messages);
  console.log(`\n=== TOOL INTERACTIONS — what the agent fetched (${interactions.length}) ===`);
  for (const it of interactions) {
    console.log(`  #${it.step}  ${it.tool}  ${JSON.stringify(it.arguments)}`);
    printResult(it.tool, it.result);
  }
  if (interactions.length === 0) console.log("  (the agent proposed from the seed alone, no tool calls)");

  const record = {
    generated_at: new Date().toISOString(),
    source: { user: maskEmail(address), limit: env.limit, since_days: env.sinceDays },
    counts: { fetched: emails.length, look: look.length, tool_interactions: interactions.length },
    seed,
    interactions,
    transcript: messages, // the complete system + seed + every tool call/result the agent saw
  };
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const outPath = `${outDir()}gmail-agent-trace-${stamp}.json`;
  writeFileSync(outPath, JSON.stringify(record, null, 2));
  console.log(`\nSaved the full agent input transcript (seed + all tool calls/results) to:\n  ${outPath}`);
}

main().catch((error) => {
  console.error("[gmail-agent-trace] failed:", error instanceof Error ? error.message : error);
  process.exit(1);
});
