import { test } from "node:test";
import assert from "node:assert/strict";
import { MemorySaver } from "@langchain/langgraph";
import { buildGraph, type RouteOutcome } from "../src/graph/graph.ts";
import { emptyExecutor, fakeChat, mail } from "./helpers.ts";

// One scan with two merchants: a genuine subscription (Netflix) and repeated one-off orders
// (Uber). The MODEL calls both subscriptions; the deterministic cadence guard must still demote
// Uber to a near-miss while Netflix is presented.
const rawMessages = [
  mail({ id: "n1", sender: "billing@netflix.com", subject: "Your Netflix receipt", snippet: "Your membership renews — $15.99 monthly" }),
  mail({ id: "u1", sender: "receipts@uber.com", subject: "Your Tuesday trip with Uber", snippet: "Total $12.40", received_at: "2026-08-02T00:00:00Z" }),
  mail({ id: "u2", sender: "receipts@uber.com", subject: "Your Friday trip with Uber", snippet: "Total $28.10", received_at: "2026-08-05T00:00:00Z" }),
  mail({ id: "u3", sender: "receipts@uber.com", subject: "Your trip with Uber", snippet: "Total $7.65", received_at: "2026-08-09T00:00:00Z" }),
];

const assess = (canonical: string): string => {
  if (canonical === "netflix") {
    return JSON.stringify({
      existence: "high", recurrence: "recurring", merchant_name: "Netflix",
      amount: 15.99, currency: "USD", billing_cycle: "monthly", category: "entertainment",
      event_type: "created", confidence: 0.9, evidence_refs: ["n1"],
    });
  }
  return JSON.stringify({
    existence: "high", recurrence: "recurring", merchant_name: "Uber",
    amount: 12.4, currency: "USD", billing_cycle: "monthly",
    event_type: "created", confidence: 0.8, evidence_refs: ["u1"],
  });
};

test("graph presents a real subscription and demotes repeated one-off orders", async () => {
  const app = buildGraph({ chat: fakeChat({ assess }), executeTool: emptyExecutor }, new MemorySaver());
  const final = await app.invoke({ rawMessages }, { configurable: { thread_id: "g1" } });
  const results = final.results as RouteOutcome[];

  assert.equal(results.length, 2);
  const netflix = results.find((r) => r.assessment.canonical_merchant_key === "netflix")!;
  const uber = results.find((r) => r.assessment.canonical_merchant_key === "uber")!;

  assert.equal(netflix.kind, "present");
  assert.equal(netflix.assessment.billing_cycle, "monthly");
  assert.equal(netflix.assessment.recurrence, "recurring");

  assert.equal(uber.kind, "near_miss");
  assert.equal(uber.assessment.recurrence, "one_off");
  assert.equal(uber.kind === "near_miss" && uber.reason, "variable_repeated_amounts");
});

test("graph produces no outcomes for an empty inbox", async () => {
  const app = buildGraph({ chat: fakeChat({ assess }), executeTool: emptyExecutor }, new MemorySaver());
  const final = await app.invoke({ rawMessages: [] }, { configurable: { thread_id: "g2" } });
  assert.equal((final.results as RouteOutcome[]).length, 0);
});
