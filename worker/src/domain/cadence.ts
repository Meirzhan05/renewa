// Recurring-vs-one-off discriminator. The message-centric pipeline treated any pile of receipts
// from one merchant as a possible subscription, so frequent one-off purchases (Uber rides,
// food-delivery orders) were mistaken for recurring charges. This module derives deterministic
// cadence/amount-stability features from a merchant's messages and reconciles them with the
// model's recurrence claim before routing. Pure — no I/O, fully unit-testable.

import {
  recomputeCompleteness,
  type MerchantAssessment,
  type RecurrenceKind,
  type ToolMatch,
} from "./reasoner.ts";

// Explicit recurrence language: any of these in the evidence is decisive for "recurring".
const RECURRENCE_KEYWORDS = [
  "subscription",
  "subscribe",
  "membership",
  "member since",
  "renews",
  "renewal",
  "auto-renew",
  "auto renew",
  "recurring",
  "billing cycle",
  "next payment",
  "plan",
  "uber one",
  "prime membership",
  "dashpass",
  "monthly",
  "yearly",
  "annual",
  "per month",
  "per year",
  "/mo",
  "/yr",
];

// Transactional language typical of one-off purchases (rides, orders, single checkouts).
const TRANSACTIONAL_KEYWORDS = [
  "your trip",
  "your ride",
  "trip with",
  "your order",
  "order confirmation",
  "order #",
  "delivered",
  "your delivery",
  "thanks for your order",
  "receipt for your",
  "your purchase",
];

export type CadenceFeatures = {
  messageCount: number;
  amounts: number[];
  amountCount: number;
  // (max - min) / median across the observed amounts; 0 when fewer than two amounts.
  relativeSpread: number;
  medianIntervalDays: number | null;
  hasRecurrenceKeyword: boolean;
  hasTransactionalKeyword: boolean;
};

export type RecurrenceVerdict = {
  recurrence: RecurrenceKind;
  reason: string;
};

// Above this spread, repeated amounts look like variable one-off purchases, not a fixed plan.
const VARIABLE_SPREAD = 0.25;
// Below this spread, repeated amounts look like the same charge recurring.
const STABLE_SPREAD = 0.1;

/** Parse the first monetary amount from a piece of text, or null. */
export function extractAmount(text: string): number | null {
  // $12.34 / €9,99 / 12.34 USD / ₸ 4500
  const symbol = text.match(/[$€£₸¥]\s?([\d.,]+)/);
  const code = text.match(/([\d.,]+)\s?(?:usd|eur|gbp|kzt|cad|aud|jpy)\b/i);
  const raw = symbol?.[1] ?? code?.[1];
  if (!raw) return null;
  return normalizeAmount(raw);
}

function normalizeAmount(raw: string): number | null {
  let cleaned = raw.trim();
  // Treat a comma as a decimal separator when it is the last group of two digits (European).
  if (/,\d{2}$/.test(cleaned) && !/\.\d/.test(cleaned)) cleaned = cleaned.replace(/\./g, "").replace(",", ".");
  else cleaned = cleaned.replace(/,/g, "");
  const value = Number(cleaned);
  if (!Number.isFinite(value) || value <= 0) return null;
  return value;
}

function hasAny(haystack: string, needles: string[]): boolean {
  const lower = haystack.toLowerCase();
  return needles.some((n) => lower.includes(n));
}

function median(values: number[]): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0 ? (sorted[mid - 1]! + sorted[mid]!) / 2 : sorted[mid]!;
}

/** Derive deterministic cadence features from a merchant's seed messages. Pure. */
export function computeCadenceFeatures(messages: ToolMatch[]): CadenceFeatures {
  const combined = messages.map((m) => `${m.subject}\n${m.snippet}`).join("\n");
  const amounts: number[] = [];
  for (const m of messages) {
    const amount = extractAmount(`${m.subject}\n${m.snippet}`);
    if (amount !== null) amounts.push(amount);
  }
  const med = median(amounts);
  const relativeSpread =
    amounts.length >= 2 && med > 0 ? (Math.max(...amounts) - Math.min(...amounts)) / med : 0;

  const times = messages
    .map((m) => Date.parse(m.received_at))
    .filter((t) => Number.isFinite(t))
    .sort((a, b) => a - b);
  let medianIntervalDays: number | null = null;
  if (times.length >= 2) {
    const gaps: number[] = [];
    for (let i = 1; i < times.length; i++) gaps.push((times[i]! - times[i - 1]!) / 86_400_000);
    medianIntervalDays = median(gaps);
  }

  return {
    messageCount: messages.length,
    amounts,
    amountCount: amounts.length,
    relativeSpread,
    medianIntervalDays,
    hasRecurrenceKeyword: hasAny(combined, RECURRENCE_KEYWORDS),
    hasTransactionalKeyword: hasAny(combined, TRANSACTIONAL_KEYWORDS),
  };
}

/**
 * Deterministic recurrence verdict from features alone. Explicit recurrence language wins; then
 * stable repeated amounts read as recurring and widely varying repeated amounts read as one-off;
 * otherwise inconclusive.
 */
export function classifyRecurrence(features: CadenceFeatures): RecurrenceVerdict {
  if (features.hasRecurrenceKeyword) return { recurrence: "recurring", reason: "recurrence_keyword" };
  if (features.amountCount >= 2) {
    if (features.relativeSpread >= VARIABLE_SPREAD) {
      return { recurrence: "one_off", reason: "variable_repeated_amounts" };
    }
    if (features.relativeSpread <= STABLE_SPREAD) {
      return { recurrence: "recurring", reason: "stable_repeated_amount" };
    }
  }
  if (features.hasTransactionalKeyword && features.messageCount >= 2) {
    return { recurrence: "one_off", reason: "transactional_language" };
  }
  return { recurrence: "unknown", reason: "insufficient_signal" };
}

/**
 * Reconcile the model's recurrence claim with the deterministic verdict, then apply the guard:
 * a merchant that is one-off (by either the model or hard cadence evidence) is NOT a subscription,
 * so existence is downgraded to low — which routes it to a near-miss rather than a false candidate.
 * Pure; recomputes completeness so routing sees the reconciled picture.
 */
export function reconcileRecurrence(
  assessment: MerchantAssessment,
  features: CadenceFeatures,
): MerchantAssessment {
  const det = classifyRecurrence(features);
  let recurrence: RecurrenceKind = assessment.recurrence;

  // Hard cadence evidence of variable repeated purchases overrides model optimism.
  if (det.recurrence === "one_off") recurrence = "one_off";
  // Fill an unknown from either direction.
  else if (recurrence === "unknown") recurrence = det.recurrence;

  const next: MerchantAssessment = { ...assessment, recurrence };
  if (recurrence === "one_off") {
    next.existence = "low";
    if (!next.abstain_reason || next.abstain_reason === "low_existence") {
      next.abstain_reason = det.recurrence === "one_off" ? det.reason : "one_off_purchase";
    }
  }
  return recomputeCompleteness(next);
}
