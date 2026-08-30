## Context

The managed scan keeps a durable execution ledger (`inbox_agent_executions`) alongside trigger.dev.
A page task claims an execution (`claim_inbox_agent_execution`, sets `lease_expires_at`), heartbeats
every 45s (`heartbeat_inbox_agent_execution`, extends the lease), and on finish calls
`complete_inbox_agent_execution`. Run completion is owned by `finalize_email_scan_run_if_drained`,
which completes a run only when every `email_scan_jobs` and `scan_jobs` row is terminal.

The failure mode (run `e46d7e75`): page 21's analysis hung (no model-call timeout). The heartbeat
loop kept the lease alive only while the process lived; when the task exceeded its 1-hour `maxDuration`
trigger.dev killed it. The kill skipped the task's `try/finally`, so `scan_jobs` and the execution
stayed `running`, the lease expired, and — because nothing runs `recover_expired_inbox_agent_executions()`
— the orphan was never reclaimed. The run stayed `running` forever.

`recover_expired_inbox_agent_executions()` already flips `state='running' and lease_expires_at <= now()`
to `retryable` (or `failed` at attempt_count ≥ 3), but it stops there: it does not touch `scan_jobs` or
the run, and no scheduler calls it.

## Goals / Non-Goals

**Goals:**
- No single page can hang more than a couple of minutes (bounded model calls + `maxDuration`).
- An orphaned execution (killed/crashed task) is reclaimed automatically and the run reaches a terminal
  state with the candidates already found — never a permanent deadlock.
- Reuse the existing lease/heartbeat/retry machinery; add scheduling + finalize wiring, not a new model.

**Non-Goals:**
- Re-architecting the orchestrator's `*AndWait` model.
- The parallel-analysis change (separate).
- Recovering the *content* of the lost page (it is retried or dropped; findings from other pages stand).

## Decisions

### D1 — Bound the page analysis with a timeout (prevention)
Wrap the model/LLM calls in `analyzeInboxPage` (and the page as a whole) in a timeout (e.g. per-call
~90s, per-page ~5m, configurable). On timeout the task throws. *Why:* a thrown error is retried by
trigger.dev's native policy (`maxAttempts: 3`); a page that keeps timing out fails the batch, so the
orchestrator throws and the run fails cleanly. This alone prevents the hour-long hang.
*Alternative — rely only on `maxDuration`:* rejected as the sole fix; it wastes up to an hour per hang
and (as seen) leaves orphans when the kill skips cleanup.

### D2 — Lower `maxDuration` to a realistic page budget (backstop)
Drop the `analyze-inbox-page` `maxDuration` from 3600s to ~600s. *Why:* even if a hang escapes D1, the
task is killed and retried within minutes, and the parent's `*AndWait` unblocks in minutes instead of
an hour. Keep the run orchestrator's own duration generous enough for a full multi-page scan.

### D3 — Schedule the reaper (recovery)
Invoke `recover_expired_inbox_agent_executions()` on a fixed cadence (~60–90s). Prefer **pg_cron** if
available (self-contained, no external caller); otherwise add an authenticated edge action (e.g.
`reap`) alongside the existing `automatic` / `renew_monitoring` monitor endpoints and drive it from the
same schedule that already pings the monitor. *Why:* the recovery routine exists but is inert without a
caller.

### D4 — Recovery must unblock the run, not just the execution
Extend `recover_expired_inbox_agent_executions()` so that when it marks an execution **failed** (past
the retry cap) it also, in the same transaction: fails the linked `scan_jobs` row (via `scan_job_id`)
and calls `finalize_email_scan_run_if_drained(scan_run_id)`. *Why:* today a reaped execution still
leaves `scan_jobs` running, so the run never drains. With this, a terminally-dead page resolves the run
to `failed`/partial with its already-found candidates surfaced. Retryable executions are left for
trigger.dev's native retry / re-claim; only the give-up path finalizes.

## Risks / Trade-offs

- **A timeout aborts a legitimately slow model call** → Mitigation: budgets tuned above observed p95;
  a retry follows, so a transient slow call is not fatal.
- **Reaper races the task's own completion** → Mitigation: recovery only touches `state='running' AND
  lease_expires_at <= now()`; a live task heartbeats and keeps its lease, so it is never reaped.
  `finalize_*` is idempotent and `for update`-locked.
- **pg_cron may not be enabled on the project** → Mitigation: fall back to the edge `reap` action on
  the existing monitor schedule.
- **Double-fail a scan_jobs row** → Mitigation: guard the update to `status in ('pending','running')`;
  finalize is idempotent.

## Migration Plan

1. Migration: redefine `recover_expired_inbox_agent_executions()` to fail the linked `scan_jobs` and
   finalize on give-up; if using pg_cron, schedule it.
2. Worker: add the timeout in `page-analysis.ts`; lower `analyze-inbox-page` `maxDuration`. Redeploy the
   trigger.dev worker.
3. Edge (only if not pg_cron): add the authenticated `reap` action; wire it to the monitor schedule.
4. Rollback: unschedule the reaper and/or revert the worker timeout; the extra columns/logic are inert
   if unscheduled.

## Open Questions

- pg_cron vs edge-cron for scheduling — depends on whether pg_cron is enabled on the project.
- Exact timeout budgets (per-call vs per-page) — set from observed model latency, then tune.
- Should a give-up finalize mark the run `failed` or a softer `partial`/`completed`-with-note when some
  candidates were found? (The finalizer currently yields `failed` if any page failed.)
