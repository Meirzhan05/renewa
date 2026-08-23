import { firstMissingField, routeAssessment } from "./discovery-routing.ts";
import type { MerchantAssessment } from "./agentic-reasoner.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function assessment(overrides: Partial<MerchantAssessment> = {}): MerchantAssessment {
  return {
    canonical_merchant_key: "anthropic",
    merchant_name: "Anthropic",
    existence: "high",
    completeness: "complete",
    missing_fields: [],
    event_type: "created",
    amount: 20,
    currency: "USD",
    billing_cycle: "monthly",
    event_date: "2026-08-22",
    renewal_date: "2026-09-22",
    category: "work",
    confidence: 0.9,
    evidence_refs: ["seed-1"],
    abstain_reason: null,
    budget_exhausted: false,
    ...overrides,
  };
}

Deno.test("high existence + complete → present a candidate", () => {
  const outcome = routeAssessment(assessment());
  assert(outcome.kind === "present", "complete strong merchant is presented");
});

Deno.test("high existence + missing cycle → ask one clarification (the Anthropic fix)", () => {
  const outcome = routeAssessment(assessment({
    completeness: "incomplete",
    missing_fields: ["billing_cycle"],
    billing_cycle: null,
  }));
  assert(outcome.kind === "clarify", "incomplete strong merchant asks a clarification");
  assert(outcome.kind === "clarify" && outcome.field === "billing_cycle", "asks about the cycle");
});

Deno.test("low existence → near-miss, no prompt", () => {
  const outcome = routeAssessment(assessment({
    existence: "low",
    abstain_reason: "no_paid_evidence",
  }));
  assert(outcome.kind === "near_miss", "weak signal is a near-miss");
  assert(outcome.kind === "near_miss" && outcome.reason === "no_paid_evidence", "reason kept");
});

Deno.test("high existence but below confidence floor → near-miss, never auto-present", () => {
  const outcome = routeAssessment(assessment({ confidence: 0.2 }));
  assert(outcome.kind === "near_miss", "low confidence does not surface");
});

Deno.test("firstMissingField prefers billing_cycle", () => {
  const field = firstMissingField(assessment({ missing_fields: ["amount", "billing_cycle"] }));
  assert(field === "billing_cycle", "cycle is preferred when missing");
});
