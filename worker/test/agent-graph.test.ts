import { test } from "node:test";
import assert from "node:assert/strict";
import { MemorySaver } from "@langchain/langgraph";
import { buildAgentGraph } from "../src/agent/agent-graph.ts";
import { inMemoryReconcileReaders } from "../src/agent/tools.ts";
import type { ProposalCandidate } from "../src/agent/types.ts";
import type { ChatFn, ToolCall } from "../src/llm/client.ts";
import { createScanReadExecutor, filterIncremental, runTwoTierScan } from "../src/agent/pipeline.ts";
import { mail } from "./helpers.ts";

// A model driven by a fixed script of turns. Each turn is either tool calls or a final message.
function scriptedChat(turns: Array<{ content?: string; toolCalls?: ToolCall[] }>): ChatFn {
  let i = 0;
  return async () => {
    const turn = turns[i] ?? { content: "done" };
    i += 1;
    return { content: turn.content ?? "", toolCalls: turn.toolCalls ?? [], tokens: 10 };
  };
}

function proposeCall(candidate: Record<string, unknown>): ToolCall {
  return { id: "call-propose", name: "propose", arguments: JSON.stringify(candidate) };
}

const netflix = mail({ id: "n1", sender: "billing@netflix.com", subject: "Your Netflix receipt", snippet: "renews $15.99 monthly" });

test("agent proposes a subscription and the run terminates", async () => {
  const chat = scriptedChat([
    { toolCalls: [proposeCall({ merchant_name: "Netflix", recurrence: "recurring", amount: 15.99, currency: "USD", billing_cycle: "monthly", evidence_refs: ["n1"] })] },
    { content: "Proposed Netflix." },
  ]);
  const app = buildAgentGraph(
    { chat, readExecutor: createScanReadExecutor([netflix]), reconcile: inMemoryReconcileReaders({}) },
    new MemorySaver(),
  );
  const final = await app.invoke({ rawMessages: [netflix] }, { configurable: { thread_id: "a1" } });
  const proposals = final.proposals as ProposalCandidate[];
  assert.equal(proposals.length, 1);
  assert.equal(proposals[0]!.merchant_key, "netflix");
  assert.equal(proposals[0]!.billing_cycle, "monthly");
});

test("agent does NOT re-propose a merchant the user already tracks (reconcile + dedup)", async () => {
  const chat = scriptedChat([
    { toolCalls: [proposeCall({ merchant_name: "Netflix", recurrence: "recurring", evidence_refs: ["n1"] })] },
    { content: "Netflix already tracked." },
  ]);
  const app = buildAgentGraph(
    {
      chat,
      readExecutor: createScanReadExecutor([netflix]),
      reconcile: inMemoryReconcileReaders({
        subscriptions: [{ merchant_key: "netflix", merchant_name: "Netflix", amount: 15.99, currency: "USD", billing_cycle: "monthly", status: "active" }],
      }),
    },
    new MemorySaver(),
  );
  const final = await app.invoke({ rawMessages: [netflix] }, { configurable: { thread_id: "a2" } });
  assert.equal((final.proposals as ProposalCandidate[]).length, 0);
});

test("agent respects a prior rejection (suppressed) — no re-propose", async () => {
  const chat = scriptedChat([
    { toolCalls: [proposeCall({ merchant_name: "Netflix", recurrence: "recurring", evidence_refs: ["n1"] })] },
    { content: "done" },
  ]);
  const app = buildAgentGraph(
    {
      chat,
      readExecutor: createScanReadExecutor([netflix]),
      reconcile: inMemoryReconcileReaders({
        priors: [{ merchant_key: "netflix", disposition: "rejected", field_priors: {}, aliases: [] }],
      }),
    },
    new MemorySaver(),
  );
  const final = await app.invoke({ rawMessages: [netflix] }, { configurable: { thread_id: "a3" } });
  assert.equal((final.proposals as ProposalCandidate[]).length, 0);
});

test("the loop always terminates under a tight budget even if the model never stops", async () => {
  // A model that ALWAYS asks to search — only the budget can stop it.
  const chat: ChatFn = async () => ({
    content: "",
    toolCalls: [{ id: "s", name: "search_inbox", arguments: JSON.stringify({ query: "receipt" }) }],
    tokens: 10,
  });
  const app = buildAgentGraph(
    { chat, readExecutor: createScanReadExecutor([netflix]), reconcile: inMemoryReconcileReaders({}), budget: { maxIterations: 3, maxToolCalls: 10, maxFetches: 4, maxTokens: 100_000, wallClockMs: 60_000 } },
    new MemorySaver(),
  );
  const final = await app.invoke({ rawMessages: [netflix] }, { configurable: { thread_id: "a4" } });
  assert.ok(Array.isArray(final.proposals));
  assert.ok((final.iters as number) <= 4); // stopped at the iteration cap, did not run away
});

test("filterIncremental keeps only mail newer than the watermark", () => {
  const msgs = [
    mail({ id: "old", received_at: "2026-08-01T00:00:00Z" }),
    mail({ id: "new", received_at: "2026-08-10T00:00:00Z" }),
  ];
  const kept = filterIncremental(msgs, "2026-08-05T00:00:00Z").map((m) => m.id);
  assert.deepEqual(kept, ["new"]);
  assert.equal(filterIncremental(msgs, undefined).length, 2);
});

test("runTwoTierScan triages then proposes through the agent", async () => {
  const shop = mail({ id: "mk1", sender: "deals@shop.com", subject: "Weekend sale 50% off", snippet: "unsubscribe" });
  const triageChat: ChatFn = async () => ({
    content: JSON.stringify({ results: [
      { message_id: "n1", decision: "look" },
      { message_id: "mk1", decision: "skip" },
    ] }),
    toolCalls: [],
    tokens: 5,
  });
  const agentChat = scriptedChat([
    { toolCalls: [proposeCall({ merchant_name: "Netflix", recurrence: "recurring", amount: 15.99, currency: "USD", billing_cycle: "monthly", evidence_refs: ["n1"] })] },
    { content: "done" },
  ]);
  const result = await runTwoTierScan([netflix, shop], {
    chat: agentChat,
    triageChat,
    reconcile: inMemoryReconcileReaders({}),
    threadId: "two-tier-1",
  });
  assert.equal(result.triage.lookCount, 1);
  assert.equal(result.triage.skipCount, 1);
  assert.equal(result.proposals.length, 1);
  assert.equal(result.proposals[0]!.merchant_key, "netflix");
});
