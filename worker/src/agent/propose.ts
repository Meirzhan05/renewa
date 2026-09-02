// The proposal write gate. `propose` is the agent's ONLY side effect and it writes a *proposal*,
// never a subscription — a human confirms/edits/rejects downstream. Two guards live here:
//   1. validateProposal — coerces the model's raw args into a strictly typed, bounded candidate and
//      DROPS anything else. There is no free-text field, so untrusted email content cannot be
//      smuggled onto the human-facing card (the anti-exfil wall).
//   2. dedupeProposal — deterministic idempotency: reject a proposal that exact-matches a merchant
//      the user already tracks or has already rejected/suppressed. This filters duplicate PROPOSALS,
//      not subscriptions; it is plumbing, not judgment.
// Pure — no I/O.

import {
  billingCycles,
  billingEventTypes,
  canonicalMerchantKey,
  resolveMerchantIdentity,
  subscriptionCategories,
} from "../domain/email.ts";
import type { ProposalCandidate, RecurrenceKind } from "./types.ts";

const MERCHANT_NAME_MAX = 120;
const MAX_EVIDENCE_REFS = 12;
const recurrenceKinds: readonly RecurrenceKind[] = ["recurring", "one_off", "unknown"];

export type ValidationResult =
  | { ok: true; proposal: ProposalCandidate }
  | { ok: false; reason: string };

/**
 * Coerce raw model output into a typed proposal. Unknown/extra keys are ignored (never surfaced),
 * out-of-range values are nulled, and a merchant name is required. The merchant name is bounded and
 * control-stripped so it cannot carry markup or newlines onto the card.
 *
 * `evidenceSender` — the sender of the email backing this proposal, when known — makes the merchant
 * key identity-bearing rather than a slug of the model's chosen label, so the dedup guard below
 * recognises one vendor named two ways ("Anthropic" / "Anthropic (Claude Pro)") as a duplicate. The
 * sender is used ONLY to derive that key; it never reaches a human-facing field, so the anti-exfil
 * wall is unchanged.
 */
export function validateProposal(raw: unknown, evidenceSender?: string): ValidationResult {
  if (typeof raw !== "object" || raw === null) return { ok: false, reason: "not_an_object" };
  const r = raw as Record<string, unknown>;

  const merchant_name = sanitizeName(r.merchant_name);
  if (!merchant_name) return { ok: false, reason: "missing_merchant_name" };

  const recurrence: RecurrenceKind = recurrenceKinds.includes(r.recurrence as RecurrenceKind)
    ? (r.recurrence as RecurrenceKind)
    : "unknown";

  const proposal: ProposalCandidate = {
    merchant_key: evidenceSender
      ? resolveMerchantIdentity(evidenceSender, merchant_name)
      : canonicalMerchantKey(merchant_name),
    merchant_name,
    recurrence,
    amount: coerceAmount(r.amount),
    currency: coerceCurrency(r.currency),
    billing_cycle: coerceEnum(r.billing_cycle, billingCycles),
    category: coerceEnum(r.category, subscriptionCategories),
    event_type: coerceEnum(r.event_type, billingEventTypes),
    event_date: coerceISODate(r.event_date),
    renewal_date: coerceISODate(r.renewal_date),
    confidence: coerceUnit(r.confidence),
    evidence_refs: coerceRefs(r.evidence_refs),
  };
  return { ok: true, proposal };
}

export type DedupSets = { tracked: Set<string>; suppressed: Set<string> };

export type DedupResult =
  | { ok: true; proposal: ProposalCandidate }
  | { ok: false; reason: "duplicate_tracked" | "duplicate_suppressed" };

/**
 * Deterministic idempotency guard on the write. Rejects a proposal whose canonical merchant key
 * already appears in the user's tracked subscriptions or in their rejected/suppressed set, so a
 * re-scan cannot re-surface something the user already resolved.
 */
export function dedupeProposal(proposal: ProposalCandidate, sets: DedupSets): DedupResult {
  if (sets.tracked.has(proposal.merchant_key)) return { ok: false, reason: "duplicate_tracked" };
  if (sets.suppressed.has(proposal.merchant_key)) return { ok: false, reason: "duplicate_suppressed" };
  return { ok: true, proposal };
}

// --- coercion helpers ---------------------------------------------------------------------------

function sanitizeName(value: unknown): string {
  if (typeof value !== "string") return "";
  // Drop control characters (code point < 32, or DEL) so a name cannot carry newlines, markup, or
  // terminal escapes onto the human-facing card; then collapse whitespace and bound the length.
  const stripped = Array.from(value)
    .filter((ch) => {
      const code = ch.codePointAt(0) ?? 0;
      return code >= 32 && code !== 127;
    })
    .join("");
  return stripped.replace(/\s+/g, " ").trim().slice(0, MERCHANT_NAME_MAX);
}

function coerceAmount(value: unknown): number | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  if (value <= 0 || value > 1_000_000) return null;
  return value;
}

function coerceCurrency(value: unknown): string | null {
  if (typeof value !== "string" || !/^[A-Za-z]{3}$/.test(value)) return null;
  return value.toUpperCase();
}

function coerceEnum<T extends readonly string[]>(value: unknown, values: T): T[number] | null {
  return typeof value === "string" && values.includes(value) ? (value as T[number]) : null;
}

function coerceISODate(value: unknown): string | null {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
  const date = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(date.valueOf()) && date.toISOString().slice(0, 10) === value ? value : null;
}

function coerceUnit(value: unknown): number {
  const n = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(n)) return 0;
  return Math.min(1, Math.max(0, n));
}

function coerceRefs(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.filter((v): v is string => typeof v === "string").slice(0, MAX_EVIDENCE_REFS);
}
