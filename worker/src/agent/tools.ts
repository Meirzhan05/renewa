// The autonomous agent's read-only tool belt, plus the one human-gated write (`propose`). The agent
// PROPOSES tool calls; `authorizeAgentToolCall` (authorizer.ts) AUTHORIZES them and the budget
// guarantees termination. Reads are read-only over the connected account; the only side effect is
// `propose`, which enqueues a *proposal* (never a subscription) and is content-validated in
// propose.ts. There is deliberately no tool that writes a subscription, tracks, or sends outward.

import { billingCycles, subscriptionCategories, billingEventTypes } from "../domain/email.ts";
import { computeNumericCadence, type CadenceInput, type NumericCadence } from "../domain/cadence-features.ts";
import type { ToolSchema } from "../llm/client.ts";
import type { PriorDecision, ToolMatch, TrackedSubscription } from "./types.ts";

// --- Tool schemas advertised to the model -------------------------------------------------------

export function agentToolSchemas(): ToolSchema[] {
  return [
    {
      name: "search_inbox",
      description:
        "Search the user's connected inbox (metadata only) for messages matching a query. " +
        "Read-only. Use this to narrow the inbox instead of asking to read everything.",
      parameters: {
        type: "object",
        properties: { query: { type: "string", description: "keywords, e.g. a sender or 'receipt'" } },
        required: ["query"],
      },
    },
    {
      name: "fetch",
      description:
        "Fetch the full sanitized body of ONE message you have already surfaced via search, by id.",
      parameters: {
        type: "object",
        properties: { message_id: { type: "string" } },
        required: ["message_id"],
      },
    },
    {
      name: "compute_cadence",
      description:
        "Compute numeric cadence evidence (amounts, price spread, median interval in days) across " +
        "messages you have surfaced. Use it to judge recurring vs. repeated one-off — you decide.",
      parameters: {
        type: "object",
        properties: {
          message_ids: { type: "array", items: { type: "string" }, description: "surfaced ids" },
        },
        required: ["message_ids"],
      },
    },
    {
      name: "list_current_subscriptions",
      description:
        "List the subscriptions the user already tracks, to reconcile (price/lifecycle changes) " +
        "instead of proposing a duplicate. Read-only.",
      parameters: { type: "object", properties: {} },
    },
    {
      name: "list_prior_decisions",
      description:
        "List prior proposals and their outcomes (confirmed / rejected / suppressed), learned field " +
        "priors, and merchant aliases. Honor these: do not re-propose a rejected merchant absent " +
        "materially new evidence. Read-only.",
      parameters: {
        type: "object",
        properties: { merchant: { type: "string", description: "optional merchant filter" } },
      },
    },
    {
      name: "propose",
      description:
        "Propose a subscription candidate for the user to confirm. This does NOT add anything — a " +
        "human confirms. Fields are typed; there is no free-text field. Call once per subscription.",
      parameters: {
        type: "object",
        properties: {
          merchant_name: { type: "string" },
          recurrence: { type: "string", enum: ["recurring", "one_off", "unknown"] },
          amount: { type: ["number", "null"] },
          currency: { type: ["string", "null"], description: "3-letter code" },
          billing_cycle: { type: ["string", "null"], enum: [...billingCycles, null] },
          category: { type: ["string", "null"], enum: [...subscriptionCategories, null] },
          event_type: { type: ["string", "null"], enum: [...billingEventTypes, null] },
          event_date: { type: ["string", "null"], description: "YYYY-MM-DD" },
          renewal_date: { type: ["string", "null"], description: "YYYY-MM-DD" },
          confidence: { type: "number" },
          evidence_refs: { type: "array", items: { type: "string" } },
        },
        required: ["merchant_name", "recurrence", "evidence_refs"],
      },
    },
  ];
}

// --- compute_cadence: pure perception over surfaced messages ------------------------------------

export type CadenceResult = { tool: "compute_cadence"; cadence: NumericCadence };

/** Run the cadence math over the given surfaced messages. Pure; the agent interprets the result. */
export function computeCadence(messages: CadenceInput[]): CadenceResult {
  return { tool: "compute_cadence", cadence: computeNumericCadence(messages) };
}

// --- Reconcile readers: interfaces + an in-memory implementation for tests/dev ------------------

// The live bindings read the app's subscription table and the cross-repo learning tables
// (merchant_review_priors, reviewed_merchant_aliases, merchant_discovery_suppressions). Those are
// the integration seam (tasks 3.4/3.5); the agent depends only on these interfaces.
export type SubscriptionReader = () => Promise<TrackedSubscription[]>;
export type PriorDecisionReader = (merchant?: string) => Promise<PriorDecision[]>;

export type ReconcileReaders = {
  listCurrentSubscriptions: SubscriptionReader;
  listPriorDecisions: PriorDecisionReader;
};

/** In-memory reconcile readers over fixed rows. Used by tests and the offline trace/eval scripts. */
export function inMemoryReconcileReaders(data: {
  subscriptions?: TrackedSubscription[];
  priors?: PriorDecision[];
}): ReconcileReaders {
  const subscriptions = data.subscriptions ?? [];
  const priors = data.priors ?? [];
  return {
    listCurrentSubscriptions: async () => subscriptions,
    listPriorDecisions: async (merchant?: string) =>
      merchant ? priors.filter((p) => p.merchant_key === merchant) : priors,
  };
}

/** Convenience: the set of merchant keys the user already tracks (for the dedup guard). */
export function trackedKeys(subscriptions: TrackedSubscription[]): Set<string> {
  return new Set(subscriptions.map((s) => s.merchant_key));
}

/** Convenience: merchant keys the user rejected or suppressed (for the dedup guard). */
export function suppressedKeys(priors: PriorDecision[]): Set<string> {
  return new Set(
    priors.filter((p) => p.disposition === "rejected" || p.disposition === "suppressed").map((p) => p.merchant_key),
  );
}

export type { ToolMatch };
