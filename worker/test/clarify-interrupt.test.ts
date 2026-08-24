import { test } from "node:test";
import assert from "node:assert/strict";
import { Command, MemorySaver } from "@langchain/langgraph";
import { buildGraph, type ClarifyPayload, type RouteOutcome } from "../src/graph/graph.ts";
import { emptyExecutor, fakeChat, mail } from "./helpers.ts";

// Anthropic: a credible receipt with no stated billing cycle. It should PAUSE the run with a
// clarification (interrupt), and resuming with the answer should complete it into a present
// candidate — the durable human-in-the-loop that the ephemeral edge function could not do.
const rawMessages = [
  mail({ id: "a1", sender: "billing@anthropic.com", subject: "Your Anthropic receipt", snippet: "Payment of $20.00 received. Thank you." }),
];

const assess = (): string =>
  JSON.stringify({
    existence: "high", recurrence: "unknown", merchant_name: "Anthropic",
    amount: 20, currency: "USD", confidence: 0.7, evidence_refs: ["a1"],
  });

test("a cycle-less receipt interrupts for clarification, then resumes into a candidate", async () => {
  const app = buildGraph({ chat: fakeChat({ assess }), executeTool: emptyExecutor }, new MemorySaver());
  const config = { configurable: { thread_id: "clar-1" } };

  // First pass: the run pauses on a clarification instead of finishing.
  await app.invoke({ rawMessages }, config);
  const paused = await app.getState(config);
  const interrupts = (paused.tasks ?? []).flatMap((t) => t.interrupts ?? []);
  assert.equal(interrupts.length, 1, "run should be paused on exactly one clarification");

  const payload = interrupts[0]!.value as ClarifyPayload;
  assert.equal(payload.kind, "billing_cycle_check");
  assert.equal(payload.merchant, "Anthropic");
  assert.match(payload.question, /Anthropic/);

  // The user taps "Monthly"; the same run resumes and finishes.
  await app.invoke(new Command({ resume: "monthly" }), config);
  const done = await app.getState(config);
  const results = (done.values.results ?? []) as RouteOutcome[];

  assert.equal(results.length, 1);
  assert.equal(results[0]!.kind, "present");
  assert.equal(results[0]!.assessment.billing_cycle, "monthly");
});

test("answering 'not_sure' resolves the clarification without creating a candidate", async () => {
  const app = buildGraph({ chat: fakeChat({ assess }), executeTool: emptyExecutor }, new MemorySaver());
  const config = { configurable: { thread_id: "clar-2" } };

  await app.invoke({ rawMessages }, config);
  await app.invoke(new Command({ resume: "not_sure" }), config);
  const done = await app.getState(config);
  const results = (done.values.results ?? []) as RouteOutcome[];

  assert.equal(results.length, 1);
  assert.equal(results[0]!.kind, "near_miss");
});
