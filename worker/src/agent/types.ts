// Shared types for the autonomous inbox agent (Tier-2). This module is intentionally free of any
// dependency on the old per-merchant reasoner so the new engine owns its own contract and the old
// modules can be deleted (tasks 6.3/6.4) without touching the agent. Enums are reused from
// domain/email.ts — the canonical vocabulary for cycles/categories/event-types.

import type {
  BillingCycle,
  BillingEventType,
  SubscriptionCategory,
} from "../domain/email.ts";

export type RecurrenceKind = "recurring" | "one_off" | "unknown";

/** A message surfaced to the agent via search/fetch — metadata plus (on fetch) sanitized body. */
export type ToolMatch = {
  message_id: string;
  subject: string;
  sender: string;
  snippet: string;
  received_at: string;
};

/** A subscription the user already tracks — read by `list_current_subscriptions` for reconcile. */
export type TrackedSubscription = {
  merchant_key: string;
  merchant_name: string;
  amount: number | null;
  currency: string | null;
  billing_cycle: BillingCycle | null;
  status: "active" | "canceled" | "unknown";
};

/** A prior human decision the agent must honor — read by `list_prior_decisions`. */
export type PriorDecision = {
  merchant_key: string;
  // confirmed → already added; rejected/suppressed → do not re-propose absent new evidence.
  disposition: "confirmed" | "rejected" | "suppressed";
  // Learned field values from past edits (e.g. { billing_cycle: "yearly" }) to pre-fill, not override.
  field_priors: Partial<Record<string, string | number>>;
  // Alternate merchant labels the user has merged into this identity.
  aliases: string[];
};

/**
 * The agent's only write. Deliberately typed and bounded — NO free-text field — so untrusted email
 * content cannot be smuggled onto a human-facing card. Validated by `validateProposal` before it is
 * ever enqueued.
 */
export type ProposalCandidate = {
  merchant_key: string;
  merchant_name: string;
  recurrence: RecurrenceKind;
  amount: number | null;
  currency: string | null;
  billing_cycle: BillingCycle | null;
  category: SubscriptionCategory | null;
  event_type: BillingEventType | null;
  event_date: string | null;
  renewal_date: string | null;
  confidence: number;
  evidence_refs: string[];
};

/** Per-scan budget for the autonomous loop. The stop conditions that guarantee termination. */
export type AgentBudget = {
  maxIterations: number;
  maxToolCalls: number;
  maxFetches: number;
  maxTokens: number;
  wallClockMs: number;
};

// Conservative defaults. `maxFetches` is deliberately lower than `maxToolCalls` because fetch is the
// expensive tool (full bodies) and the one cost bomb an eager agent can trigger.
export const DEFAULT_AGENT_BUDGET: AgentBudget = {
  maxIterations: 12,
  maxToolCalls: 24,
  maxFetches: 8,
  maxTokens: 60_000,
  wallClockMs: 90_000,
};

// A wider budget for paid tiers (deeper cold sweep). The budget cap is also the recall cap, so it is
// tunable per tier rather than a single hardcoded value; the calibrated numbers come from eval.
const PRO_AGENT_BUDGET: AgentBudget = {
  maxIterations: 20,
  maxToolCalls: 40,
  maxFetches: 16,
  maxTokens: 120_000,
  wallClockMs: 180_000,
};

/** Resolve the per-scan budget for a user tier. Unknown/absent tiers get the conservative default. */
export function resolveBudget(tier?: string): AgentBudget {
  return (tier ?? "").toLowerCase() === "pro" ? PRO_AGENT_BUDGET : DEFAULT_AGENT_BUDGET;
}
