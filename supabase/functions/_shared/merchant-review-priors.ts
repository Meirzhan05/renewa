import {
  type BillingCycle,
  billingCycles,
  type BillingEvent,
  projectRenewalDate,
  type SubscriptionCategory,
  subscriptionCategories,
} from "./email-discovery.ts";

// Fields the agent learns from a person's own confirmed/corrected discovery
// outcomes. Deliberately narrow (low blast radius): billing cycle and category.
export const priorFields = ["billing_cycle", "category"] as const;
export type PriorField = typeof priorFields[number];

export type MerchantReviewPrior = {
  canonical_merchant_key: string;
  field: PriorField;
  value: string;
  evidence_strength: number;
};

export type PriorUpsert = {
  canonical_merchant_key: string;
  field: PriorField;
  value: string;
  evidence_strength: number;
};

export type ReviewedFieldValues = {
  billing_cycle?: unknown;
  category?: unknown;
};

export type EventOverlay = {
  billing_cycle: BillingCycle | null;
  category: SubscriptionCategory;
  renewal_date: string | null;
  appliedCycleFromPrior: boolean;
  appliedCategoryFromPrior: boolean;
};

function isBillingCycle(value: unknown): value is BillingCycle {
  return typeof value === "string" &&
    (billingCycles as readonly string[]).includes(value);
}

function isCategory(value: unknown): value is SubscriptionCategory {
  return typeof value === "string" &&
    (subscriptionCategories as readonly string[]).includes(value);
}

function validValueForField(field: PriorField, value: unknown): string | null {
  if (field === "billing_cycle") return isBillingCycle(value) ? value : null;
  return isCategory(value) ? value : null;
}

function findPrior(
  priors: MerchantReviewPrior[],
  field: PriorField,
): MerchantReviewPrior | null {
  return priors.find((prior) => prior.field === field) ?? null;
}

/**
 * Write side. Given the field values a person just confirmed (the applied,
 * user-approved values) and the merchant's existing priors, return the upserts
 * to persist. A matching prior is reinforced (strength + 1); a conflicting value
 * takes the latest value and resets strength to 1; a first observation starts at
 * strength 1. Only `confirmed` and `corrected` outcomes are learned from.
 */
export function derivePriorUpserts(input: {
  outcome: "confirmed" | "corrected" | "ignored" | "suppressed" | "canceled";
  canonicalMerchantKey: string;
  applied: ReviewedFieldValues;
  existing: MerchantReviewPrior[];
}): PriorUpsert[] {
  if (input.outcome !== "confirmed" && input.outcome !== "corrected") return [];
  if (!/^[a-z0-9][a-z0-9-]{0,79}$/.test(input.canonicalMerchantKey)) return [];

  const upserts: PriorUpsert[] = [];
  for (const field of priorFields) {
    const value = validValueForField(field, input.applied[field]);
    if (value === null) continue;
    const prior = findPrior(input.existing, field);
    const strength = prior && prior.value === value
      ? prior.evidence_strength + 1
      : 1;
    upserts.push({
      canonical_merchant_key: input.canonicalMerchantKey,
      field,
      value,
      evidence_strength: strength,
    });
  }
  return upserts;
}

/**
 * Read side. Overlay a merchant's priors onto a freshly extracted event, as
 * proposed defaults that a person still confirms. Rules:
 *  - billing_cycle: fill only when the model left it null (model value wins).
 *  - category: apply only when the model returned the low-information `other`
 *    default (any specific model category wins).
 *  - when a cycle prior fills a null cycle and no renewal date exists, project
 *    one from the event/received date so the candidate stays confirmable.
 * Fresh evidence is never overridden; this only fills gaps.
 */
export function overlayPriorsOntoEvent(
  event: BillingEvent,
  priors: MerchantReviewPrior[],
  fallbackDateISO: string,
): EventOverlay {
  let billingCycle = event.billing_cycle;
  let category = event.category;
  let renewalDate = event.renewal_date;
  let appliedCycleFromPrior = false;
  let appliedCategoryFromPrior = false;

  const cyclePrior = findPrior(priors, "billing_cycle");
  if (billingCycle === null && cyclePrior && isBillingCycle(cyclePrior.value)) {
    billingCycle = cyclePrior.value;
    appliedCycleFromPrior = true;
    if (renewalDate === null) {
      const fromDate = event.event_date ?? fallbackDateISO.slice(0, 10);
      renewalDate = projectRenewalDate(billingCycle, fromDate);
    }
  }

  const categoryPrior = findPrior(priors, "category");
  if (category === "other" && categoryPrior && isCategory(categoryPrior.value)) {
    category = categoryPrior.value;
    appliedCategoryFromPrior = true;
  }

  return {
    billing_cycle: billingCycle,
    category,
    renewal_date: renewalDate,
    appliedCycleFromPrior,
    appliedCategoryFromPrior,
  };
}
