import {
  applyVerification,
  parseVerifyVerdict,
  verifyAssessment,
} from "./discovery-verify.ts";
import type { MerchantAssessment } from "./agentic-reasoner.ts";
import type { ChatFn } from "./llm-client.ts";

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

Deno.test("ungrounded cycle is stripped and the merchant becomes incomplete", () => {
  const verified = applyVerification(assessment(), {
    existence_supported: true,
    grounded_fields: ["amount", "currency"], // billing_cycle NOT grounded
  });
  assert(verified.billing_cycle === null, "ungrounded cycle must be removed");
  assert(verified.completeness === "incomplete", "completeness recomputed");
  assert(verified.missing_fields.includes("billing_cycle"), "cycle listed missing");
  assert(verified.amount === 20, "grounded amount retained");
});

Deno.test("unsupported existence is downgraded to low", () => {
  const verified = applyVerification(assessment(), {
    existence_supported: false,
    grounded_fields: ["amount", "currency", "billing_cycle"],
  });
  assert(verified.existence === "low", "existence must downgrade");
  assert(verified.abstain_reason === "existence_unverified", "reason recorded");
});

Deno.test("parseVerifyVerdict tolerates junk", () => {
  assert(parseVerifyVerdict("not json") === null, "junk returns null");
  const verdict = parseVerifyVerdict(
    JSON.stringify({ existence_supported: true, grounded_fields: ["amount"] }),
  );
  assert(verdict?.existence_supported === true, "parses supported flag");
  assert(verdict?.grounded_fields.length === 1, "parses grounded list");
});

Deno.test("verifier outage passes the assessment through unchanged", async () => {
  const failing: ChatFn = () => Promise.reject(new Error("down"));
  const input = assessment();
  const out = await verifyAssessment(input, ["Payment of $20 monthly"], failing);
  assert(out.billing_cycle === "monthly", "fields retained on verifier outage");
  assert(out.existence === "high", "existence retained on verifier outage");
});

Deno.test("low-existence assessment skips verification", async () => {
  let called = false;
  const chat: ChatFn = () => {
    called = true;
    return Promise.resolve({ content: "{}", toolCalls: [], tokens: 0 });
  };
  await verifyAssessment(assessment({ existence: "low" }), [], chat);
  assert(!called, "no verification call for low-existence");
});
