import {
  derivePriorUpserts,
  type MerchantReviewPrior,
  overlayPriorsOntoEvent,
} from "./merchant-review-priors.ts";
import type { BillingEvent } from "./email-discovery.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

const baseEvent: BillingEvent = {
  message_id: "receipt-1",
  event_type: "renewed",
  merchant_name: "Spotify",
  amount: 119.88,
  currency: "USD",
  billing_cycle: null,
  event_date: "2026-08-20",
  renewal_date: null,
  category: "other",
  confidence: 0.94,
  evidence: "A recurring service charge was found.",
};

Deno.test("correction records a first prior at strength 1", () => {
  const upserts = derivePriorUpserts({
    outcome: "corrected",
    canonicalMerchantKey: "spotify",
    applied: { billing_cycle: "yearly" },
    existing: [],
  });
  assert(upserts.length === 1, "one upsert expected");
  assert(upserts[0].field === "billing_cycle", "cycle field");
  assert(upserts[0].value === "yearly", "learned yearly");
  assert(upserts[0].evidence_strength === 1, "strength starts at 1");
});

Deno.test("confirming an unchanged value increments strength", () => {
  const existing: MerchantReviewPrior[] = [
    { canonical_merchant_key: "spotify", field: "category", value: "entertainment", evidence_strength: 2 },
  ];
  const upserts = derivePriorUpserts({
    outcome: "confirmed",
    canonicalMerchantKey: "spotify",
    applied: { category: "entertainment" },
    existing,
  });
  assert(upserts.length === 1, "one upsert");
  assert(upserts[0].evidence_strength === 3, "strength incremented to 3");
});

Deno.test("a conflicting correction takes the latest value and resets strength", () => {
  const existing: MerchantReviewPrior[] = [
    { canonical_merchant_key: "spotify", field: "billing_cycle", value: "yearly", evidence_strength: 4 },
  ];
  const upserts = derivePriorUpserts({
    outcome: "corrected",
    canonicalMerchantKey: "spotify",
    applied: { billing_cycle: "monthly" },
    existing,
  });
  assert(upserts[0].value === "monthly", "latest value wins");
  assert(upserts[0].evidence_strength === 1, "strength reset to 1 on conflict");
});

Deno.test("unsupported or invalid applied fields produce no prior", () => {
  const upserts = derivePriorUpserts({
    outcome: "corrected",
    canonicalMerchantKey: "spotify",
    applied: { billing_cycle: "fortnightly", category: "banking" },
    existing: [],
  });
  assert(upserts.length === 0, "invalid enum values are dropped");
});

Deno.test("ignored and suppressed outcomes are never learned from", () => {
  for (const outcome of ["ignored", "suppressed", "canceled"] as const) {
    const upserts = derivePriorUpserts({
      outcome,
      canonicalMerchantKey: "spotify",
      applied: { billing_cycle: "yearly", category: "entertainment" },
      existing: [],
    });
    assert(upserts.length === 0, `${outcome} learns nothing`);
  }
});

Deno.test('"not sure" leaves no prior because no concrete value is applied', () => {
  const upserts = derivePriorUpserts({
    outcome: "corrected",
    canonicalMerchantKey: "spotify",
    applied: { billing_cycle: "not_sure" },
    existing: [],
  });
  assert(upserts.length === 0, "not_sure is not a valid cycle");
});

Deno.test("overlay fills a null cycle from a prior and projects a renewal date", () => {
  const priors: MerchantReviewPrior[] = [
    { canonical_merchant_key: "spotify", field: "billing_cycle", value: "yearly", evidence_strength: 2 },
  ];
  const overlay = overlayPriorsOntoEvent(baseEvent, priors, "2026-08-20T00:00:00Z");
  assert(overlay.billing_cycle === "yearly", "cycle filled from prior");
  assert(overlay.appliedCycleFromPrior, "flagged as applied");
  assert(overlay.renewal_date === "2027-08-20", "renewal projected one year out");
});

Deno.test("overlay never overwrites a model-provided cycle", () => {
  const priors: MerchantReviewPrior[] = [
    { canonical_merchant_key: "spotify", field: "billing_cycle", value: "yearly", evidence_strength: 9 },
  ];
  const overlay = overlayPriorsOntoEvent(
    { ...baseEvent, billing_cycle: "monthly", renewal_date: "2026-09-20" },
    priors,
    "2026-08-20T00:00:00Z",
  );
  assert(overlay.billing_cycle === "monthly", "model value wins");
  assert(!overlay.appliedCycleFromPrior, "prior not applied");
  assert(overlay.renewal_date === "2026-09-20", "model renewal preserved");
});

Deno.test("category prior applies only to the 'other' default", () => {
  const priors: MerchantReviewPrior[] = [
    { canonical_merchant_key: "spotify", field: "category", value: "entertainment", evidence_strength: 1 },
  ];
  const filled = overlayPriorsOntoEvent(baseEvent, priors, "2026-08-20T00:00:00Z");
  assert(filled.category === "entertainment", "other is replaced by prior");
  assert(filled.appliedCategoryFromPrior, "flagged applied");

  const keptSpecific = overlayPriorsOntoEvent(
    { ...baseEvent, category: "work" },
    priors,
    "2026-08-20T00:00:00Z",
  );
  assert(keptSpecific.category === "work", "specific model category wins");
  assert(!keptSpecific.appliedCategoryFromPrior, "prior not applied over specific category");
});

Deno.test("no priors leaves the event unchanged", () => {
  const overlay = overlayPriorsOntoEvent(baseEvent, [], "2026-08-20T00:00:00Z");
  assert(overlay.billing_cycle === null, "cycle unchanged");
  assert(overlay.category === "other", "category unchanged");
  assert(overlay.renewal_date === null, "renewal unchanged");
  assert(!overlay.appliedCycleFromPrior && !overlay.appliedCategoryFromPrior, "nothing applied");
});
