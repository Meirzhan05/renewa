// Re-scoped tool authorizer for the autonomous agent. The old per-merchant authorizer bounded reads
// to a single merchant's domains; the autonomous agent roams the whole connected account, so the
// scope is simply "read-only over this account". Safety does not disappear — it MOVES to the write:
// `propose` is structurally admitted here and content-validated in propose.ts (the anti-exfil wall).
// Two read guards remain because they are cheap and real: `fetch`/`compute_cadence` may only touch
// message ids the agent has ALREADY surfaced this scan (no fetching arbitrary ids it never saw).
// Pure: no I/O.

export type AccountScope = {
  // Message ids the agent has surfaced so far (seed + everything search/fetch has returned).
  known_message_ids: Set<string>;
};

export type AgentToolRequest =
  | { tool: "search_inbox"; query: string }
  | { tool: "fetch"; message_id: string }
  | { tool: "compute_cadence"; message_ids: string[] }
  | { tool: "list_current_subscriptions" }
  | { tool: "list_prior_decisions"; merchant?: string }
  | { tool: "propose"; candidate: Record<string, unknown> };

export type AgentAuthDecision =
  | { ok: true; request: AgentToolRequest }
  | { ok: false; reason: string };

const MAX_QUERY = 200;
const MAX_CADENCE_IDS = 50;

export function authorizeAgentToolCall(
  name: string,
  argsJson: string,
  scope: AccountScope,
): AgentAuthDecision {
  let args: Record<string, unknown>;
  try {
    const parsed = JSON.parse(argsJson || "{}");
    args = typeof parsed === "object" && parsed !== null ? (parsed as Record<string, unknown>) : {};
  } catch {
    return { ok: false, reason: "unparseable_arguments" };
  }

  switch (name) {
    case "search_inbox": {
      const query = typeof args.query === "string" ? args.query.trim() : "";
      if (query.length === 0) return { ok: false, reason: "empty_query" };
      if (query.length > MAX_QUERY) return { ok: false, reason: "query_too_long" };
      return { ok: true, request: { tool: "search_inbox", query } };
    }

    case "fetch": {
      const id = typeof args.message_id === "string" ? args.message_id : "";
      if (!id) return { ok: false, reason: "missing_message_id" };
      if (!scope.known_message_ids.has(id)) return { ok: false, reason: "unsurfaced_message" };
      return { ok: true, request: { tool: "fetch", message_id: id } };
    }

    case "compute_cadence": {
      const raw = Array.isArray(args.message_ids) ? args.message_ids : [];
      const ids = raw.filter((v): v is string => typeof v === "string");
      if (ids.length === 0) return { ok: false, reason: "no_message_ids" };
      if (ids.length > MAX_CADENCE_IDS) return { ok: false, reason: "too_many_message_ids" };
      const unsurfaced = ids.find((id) => !scope.known_message_ids.has(id));
      if (unsurfaced) return { ok: false, reason: "unsurfaced_message" };
      return { ok: true, request: { tool: "compute_cadence", message_ids: ids } };
    }

    case "list_current_subscriptions":
      return { ok: true, request: { tool: "list_current_subscriptions" } };

    case "list_prior_decisions": {
      const merchant = typeof args.merchant === "string" ? args.merchant.trim().slice(0, 120) : undefined;
      return { ok: true, request: { tool: "list_prior_decisions", merchant: merchant || undefined } };
    }

    case "propose":
      // Structurally admit the write; propose.ts performs the real (anti-exfil) validation.
      return { ok: true, request: { tool: "propose", candidate: args } };

    default:
      return { ok: false, reason: "unknown_tool" };
  }
}
