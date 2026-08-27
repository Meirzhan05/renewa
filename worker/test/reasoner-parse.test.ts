import { test } from "node:test";
import assert from "node:assert/strict";
import {
  finalizeAssessment,
  parseAssessment,
  recomputeCompleteness,
} from "../src/domain/reasoner.ts";

test("parseAssessment coerces fields and recomputes completeness", () => {
  const a = parseAssessment(
    JSON.stringify({
      existence: "high",
      recurrence: "recurring",
      merchant_name: "Netflix",
      amount: 15.99,
      currency: "usd",
      billing_cycle: "monthly",
      category: "entertainment",
      confidence: 0.88,
      evidence_refs: ["m1"],
    }),
    "netflix",
    "Netflix",
  );
  assert.equal(a.existence, "high");
  assert.equal(a.recurrence, "recurring");
  assert.equal(a.currency, "USD"); // upper-cased
  assert.equal(a.completeness, "complete");
  assert.deepEqual(a.missing_fields, []);
});

test("parseAssessment marks missing required fields incomplete", () => {
  const a = parseAssessment(
    JSON.stringify({ existence: "high", amount: 20, currency: "USD" }),
    "anthropic",
    "Anthropic",
  );
  assert.equal(a.completeness, "incomplete");
  assert.deepEqual(a.missing_fields, ["billing_cycle"]);
});

test("parseAssessment rejects an invalid amount and unknown recurrence", () => {
  const a = parseAssessment(
    JSON.stringify({ existence: "high", amount: -5, currency: "USD", billing_cycle: "monthly", recurrence: "weird" }),
    "x",
    "X",
  );
  assert.equal(a.amount, null);
  assert.equal(a.recurrence, "unknown");
});

test("parseAssessment falls back safely on garbage", () => {
  const a = parseAssessment("not json", "x", "X");
  assert.equal(a.existence, "low");
  assert.equal(a.abstain_reason, "unparseable_assessment");
});

test("finalizeAssessment caps confidence when the budget was exhausted", () => {
  const base = recomputeCompleteness(parseAssessment(JSON.stringify({ existence: "high", confidence: 0.95 }), "x", "X"));
  assert.equal(finalizeAssessment(base, false).confidence, 0.95);
  assert.equal(finalizeAssessment(base, true).confidence, 0.5);
  assert.equal(finalizeAssessment(base, true).budget_exhausted, true);
});
