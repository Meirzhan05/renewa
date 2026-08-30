## Why

A single page-analysis task can hang and deadlock an entire inbox scan with no recovery. Observed in
production (run `e46d7e75`): 20 of 21 pages analyzed and 4 subscriptions found (ChatGPT + Claude), but
page 21's analysis hung — most likely a model call with no timeout — and ran until the task's 1-hour
`maxDuration`, at which point trigger.dev killed it. The kill skipped the task's cleanup, so its
`scan_jobs` row and `inbox_agent_executions` record were left `running` with an expired lease. Nothing
reclaimed them, so the run sat `running` / "2100 messages" **indefinitely** and its findings never
surfaced. It had to be unstuck by hand.

The building blocks exist but are not wired up: `recover_expired_inbox_agent_executions()` already
flips expired-lease executions to `retryable`/`failed`, but (a) nothing calls it on a schedule, (b) it
does not fail the linked `scan_jobs` or finalize the run, so a run stays deadlocked even after an
execution is reaped, and (c) there is no per-page timeout, so a page hangs for an hour before anything
notices.

## What Changes

- **Bound a page analysis in time** so it can never hang for an hour: wrap the model/LLM calls (and the
  overall page) in a timeout. On timeout the task SHALL throw, letting trigger.dev's native retry
  (maxAttempts) re-run it, and a genuinely failing page SHALL fail the run cleanly instead of hanging.
- **Lower the page task `maxDuration`** from 1 hour to a realistic page budget, so even an un-timed-out
  hang is killed and retried within minutes rather than an hour.
- **Schedule the reaper**: `recover_expired_inbox_agent_executions()` SHALL run on a fixed cadence so
  expired-lease executions are reclaimed automatically.
- **Make recovery unblock the run**: when the reaper gives up on an execution (past the retry cap), it
  SHALL fail the linked `scan_jobs` row and finalize the scan run, so a dead task resolves the run to a
  terminal state (with whatever candidates were already found) instead of deadlocking.
- No change to the `email-scan` request/response contract; no iOS change required.

## Capabilities

### New Capabilities
- `managed-scan-recovery`: Defines bounded page-analysis execution and automatic recovery of orphaned
  executions so no single stuck task can deadlock a scan run.

### Modified Capabilities
<!-- none: openspec/specs is empty; the managed execution machinery lives in the in-progress
     managed-inbox-agent-workflows change, which this builds on -->

## Impact

- **Worker:** `worker/src/managed/page-analysis.ts` (timeout around the funnel / model calls);
  `worker/trigger.config.ts` or the `analyze-inbox-page` task (`maxDuration`).
- **DB / migration:** extend `recover_expired_inbox_agent_executions()` to fail the linked `scan_jobs`
  and call `finalize_email_scan_run_if_drained` on give-up; schedule it (pg_cron, or an edge cron
  endpoint invoked by the existing monitor schedule).
- **Edge (if cron via edge):** a small authenticated `reap`-style action that calls the recovery
  routine, mirroring the existing `automatic`/`renew_monitoring` monitor endpoints.
- **Behavior:** a hung or killed page no longer wedges a scan; the run finishes (partial) within
  minutes and surfaces the subscriptions already found.
- **No destructive migration**; recovery is additive.
- **Out of scope:** the parallel-analysis change (separate) and a full redesign of the orchestrator's
  wait model — this change makes the existing model self-heal.
