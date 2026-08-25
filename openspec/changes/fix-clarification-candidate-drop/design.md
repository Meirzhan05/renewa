## Context

Both the legacy and agentic pipelines resolve a clarification through one shared function,
`createCandidateFromClarification` (supabase/functions/email-scan/index.ts), called from the
resolve flow before `resolve_inbox_clarification_request`. Today that function builds a
`BillingEvent` from the stored detected event, runs `semanticValidationIssues`, and does
`if (issues.length > 0) return;` — a silent no-op. Because it does not throw, the resolve flow
still runs the RPC and marks the request resolved with effect `candidate_unblocked`. For a
cycle-less receipt the stored `renewal_date` is null and the model confidence is often `< 0.72`, so
`semanticValidationIssues` returns `["missing_renewal_date", "low_model_confidence"]` and the
candidate is dropped while the question is consumed. `semanticValidationIssues` is tuned for
*auto-detected* events; it is the wrong gate for a *human-clarified* one.

## Goals / Non-Goals

**Goals:**
- Answering an actionable clarification for an event with amount + currency reliably produces a
  reviewable candidate.
- Projecting `renewal_date` from the clarified cycle instead of requiring it from the email.
- A user answer is treated as confident, so the auto-detection confidence floor cannot drop it.
- A clarification is never both consumed and left with no candidate and no recorded reason.

**Non-Goals:**
- No change to the `resolve_inbox_clarification_request` RPC or DB schema.
- No UI work to show where an answered item went (the "D" idea) — deferred.
- No change to how *auto-detected* (non-clarified) candidates are gated.
- No change to the LangGraph worker (already avoids this).

## Decisions

### D1 — Project `renewal_date` on the clarify path
In `createCandidateFromClarification`, once `billingCycle` is known, if `event.renewal_date` is
null, compute it from a base charge date + the cycle. Base date = `event.event_date ??
event.source_received_at`. Reuse the existing renewal projection that already backs
`projected_current_renewal` (a `weekly/monthly/quarterly/yearly` → date-add). If the event already
carries a `renewal_date`, keep it. This makes "renewal_date is projected, not required" true in the
one place that was missing it.

### D2 — Treat the clarified event as human-confirmed for gating
Keep `amount` and `currency` as genuine hard requirements (a subscription needs a price). Relax only
the two "soft" checks for the clarified path: `low_model_confidence` and `missing_renewal_date`.
Implementation: run `semanticValidationIssues` as today, then for the user-clarified path drop
`low_model_confidence` and `missing_renewal_date` from the result (the latter no longer occurs once
D1 projects the date). The displayed confidence stays honest (we do not fabricate a number); the
human still must tap "Track it." Equivalent alternative considered — passing a `userClarified` flag
into `semanticValidationIssues` — rejected to avoid changing that function's contract for the
auto-detection callers.

### D3 — Make resolution conditional on the outcome (the safety net)
Change `createCandidateFromClarification` to return `{ created: boolean; reason?: string }` instead
of `void`. After the upsert (which stays `onConflict: detected_event_id, ignoreDuplicates: true`),
select the candidate by `detected_event_id`; `created = row exists` (so the idempotent duplicate
case correctly reports `true`). The resolve flow then:
- `created === true` → effect `candidate_unblocked`, resolve via RPC (unchanged).
- `created === false` for an actionable answer → effect `answered_no_candidate`, record `reason`,
  and still resolve (so the user is not re-asked in a loop). This is never labeled `candidate_unblocked`.
This guarantees a silent no-op can never again masquerade as success, satisfying the "no silent
consumption" requirement even if a future gate change reintroduces a drop.

### D4 — One fix covers both pipelines
Legacy and agentic clarifications both flow through `createCandidateFromClarification`, so D1–D3 fix
both. No branching by pipeline.

## Risks / Trade-offs

- **Projected renewal date can be approximate** when `event_date` is absent and we fall back to
  `source_received_at` (email receipt time ≈ charge time). Acceptable: the user still confirms the
  candidate, and the projected date is editable downstream.
- **Relaxing the confidence floor for clarified items** slightly lowers precision for that path, but
  a human explicitly answered and must still confirm "Track it" — the human gate absorbs the risk.
- **`answered_no_candidate` still consumes the question.** We choose recorded-consumption over
  leaving it open to avoid an infinite re-ask loop; with D1+D2 this branch should be rare
  (structurally missing amount/currency, which would not have routed to a clarification anyway).
- **Base-date selection** must prefer a real charge date (`event_date`) over receipt time to keep
  projections accurate; encoded in D1's precedence.
