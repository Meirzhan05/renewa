import { test } from "node:test";
import assert from "node:assert/strict";
import { firstMissingField, routeAssessment } from "../src/domain/routing.ts";
import { parseAssessment } from "../src/domain/reasoner.ts";

function assess(json: Record<string, unknown>) {
  return parseAssessment(JSON.stringify(json), "m", "M");
}

test("high existence + complete + confident → present", () => {
  const out = routeAssessment(
    assess({ existence: "high", amount: 9.99, currency: "USD", billing_cycle: "monthly", confidence: 0.8 }),
  );
  assert.equal(out.kind, "present");
});

test("high existence + missing cycle → clarify on billing_cycle", () => {
  const out = routeAssessment(assess({ existence: "high", amount: 20, currency: "USD", confidence: 0.7 }));
  assert.equal(out.kind, "clarify");
  assert.equal(out.kind === "clarify" && out.field, "billing_cycle");
});

test("low existence → near_miss carrying the abstain reason", () => {
  const out = routeAssessment(assess({ existence: "low", abstain_reason: "one_off_purchase" }));
  assert.equal(out.kind, "near_miss");
  assert.equal(out.kind === "near_miss" && out.reason, "one_off_purchase");
});

test("high existence but under-confident → near_miss", () => {
  const out = routeAssessment(
    assess({ existence: "high", amount: 9.99, currency: "USD", billing_cycle: "monthly", confidence: 0.1 }),
  );
  assert.equal(out.kind, "near_miss");
});

test("firstMissingField prefers billing_cycle", () => {
  const a = assess({ existence: "high", confidence: 0.7 }); // amount+currency+cycle all missing
  assert.equal(firstMissingField(a), "billing_cycle");
});
