## Context

The managed analysis path: `dispatch-inbox-pages` (scheduled) calls `reserve_inbox_agent_executions`
to lease `queued`/`retryable` page executions, triggers `analyze-inbox-page` per lease, which claims
the execution (`claim_dispatched_inbox_agent_execution` → `running`), runs the two-tier funnel, and
completes it. On any failure, `analyze-inbox-page.ts:48` calls `completeExecution(..., "retryable", …)`
— unconditionally — so the dispatcher re-leases it next tick.

Two reapers exist but neither bounds this loop: `recover_expired_inbox_agent_executions` only acts on
`leased`/`running` executions with an **expired** lease (a fast-failing retry never expires its lease),
and `recover_stalled_inbox_scan_runs` (from `surface-stalled-inbox-scans`) only acts on runs with **no**
executions. A `retryable` execution that fails quickly every tick falls between them → infinite loop
(observed 13+ hours on "Insufficient Balance").

Separately, the status `errors[]` (`email-scan/index.ts:1354`) passes raw run/job messages through, the
app renders `errors.first` verbatim (`EmailScanView.swift:1014`), and `email_scan_batch_progress` SUMs
`message_count` across scan_jobs — so retried pages inflate "checked".

## Goals / Non-Goals

**Goals:**
- No analysis loop runs unbounded; every scan reaches terminal `failed`/`partial`/`completed`.
- Permanent provider errors (billing/auth) fail fast.
- Users see safe, categorized messages and a clear failed state with retry.
- Progress counts distinct pages.

**Non-Goals:**
- Funnel quality (what it proposes) — separate.
- Provider billing/keys — operational.
- Reworking the dispatch/reserve fairness model.

## Decisions

**D1 — Cap attempts in `analyze-inbox-page`, not only in a reaper.** The task already owns the
retry/complete decision, so it is the natural place to stop: read the execution's `dispatch_attempt`
(and/or `attempt_count`) and, at/above the cap, `completeExecution(..., "failed", reason)` instead of
`"retryable"`. Failing the execution fails the job and finalizes the run. *Alternative:* rely only on
the reaper — rejected: the reaper runs on a minute cadence and only after the fact; capping at the
source stops the loop immediately and keeps the decision next to the error.

**D2 — Classify permanent errors as fatal.** A small pure `classifyProviderError(message/status)`
helper returns `permanent` for billing/quota (402 / "insufficient balance") and auth (401 / "invalid
api key"), else `transient`. `analyze-inbox-page` fails immediately on `permanent`, regardless of
attempt count. Pure + unit-testable. *Alternative:* treat everything as transient with only the cap —
rejected: wastes the full retry budget (and real money/latency) on an error that will never succeed.

**D3 — Reaper backstop for `retryable`.** Extend the recovery reaper to also fail `retryable`
executions with `dispatch_attempt >= cap` and finalize their run. Covers a worker that dies before D1
can write the terminal state. Idempotent, guarded on non-terminal state.

**D4 — Message categorization at the edge boundary.** A pure `userFacingScanError(internalReason)` maps
internal/provider strings to a small enum of user-safe messages (analysis-unavailable, inbox-auth,
generic). Applied where the status `errors[]` is assembled so nothing raw escapes. The persisted
`error_message` may keep the internal text for diagnostics; only the **response** is sanitized.
*Alternative:* sanitize at write time — rejected: loses diagnostic detail in the DB.

**D5 — Distinct failed UI state.** Add a `scanFailed` presentation state (in
`EmailDiscoveryPresentationState`) derived from a terminal `failed`/`partial` aggregate that is not a
connection problem, rendered on the scan screen with the categorized reason + a Retry that starts a new
scan. Keep `needsAttention` for connection/reconnect. Reduce-motion/theme conventions as elsewhere.

**D6 — Count pages once.** Make `email_scan_batch_progress` (or the page-ledger write) attribute
`message_count` to a page identity so retries replace rather than add — e.g. aggregate the max/last per
`(scan_run_id, page_number)` instead of summing every scan_jobs row. Keeps the counter honest.

## Risks / Trade-offs

- **Cap too low fails a legitimately flaky provider** → make the cap configurable; keep transient
  retries generous (only permanent errors fail fast).
- **Miscategorizing a transient error as permanent** stops a recoverable scan → classify narrowly
  (explicit 402/401/known strings); default to transient.
- **Over-sanitizing hides useful detail** → keep internal text in the DB; only the user-facing response
  is categorized.
- **Progress dedup miscount if page_number is not stable** → verify page identity in the ledger before
  changing the aggregation.

## Migration Plan

1. Worker: D1 cap + D2 classifier + tests; deploy the Trigger worker.
2. Migration: D3 reaper backstop (+ reuse existing pg_cron); D6 progress aggregation if it lives in SQL.
3. Edge: D4 message mapping in the status assembly; deploy `email-scan`.
4. App: D5 failed state + retry; render categorized message.
5. Verify: force a permanent error (unfunded key) → run fails fast with a friendly message and a Retry,
   no loop, progress not inflated; a transient blip still retries within the cap.

**Rollback:** worker/edge redeploy to prior; the reaper clause and progress aggregation are additive.

## Open Questions

- Exact attempt cap (proposal: reuse the existing `>= 3` convention) and whether `attempt_count` or
  `dispatch_attempt` is the right counter for analysis retries.
- Should a `partial` scan (some pages ok, some failed) show candidates **and** a soft error banner,
  rather than a full failed state? (Lean: yes — show what was found plus a non-blocking notice.)
