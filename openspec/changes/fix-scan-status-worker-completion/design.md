## Context

The iOS app learns everything about a scan from one endpoint: `POST /functions/v1/email-scan`
with `action:"status"`, polled every ~2s until the returned aggregate `status` is no longer
active (`AppStore.swift:579`–603, `EmailScanStatus.isActive`). It never reads the worker or the
DB directly.

After the cutover, `scanStatus` (`supabase/functions/email-scan/index.ts:780`) computes that
aggregate `status` from the **edge function's own connection queue**, `email_scan_jobs`:

```
index.ts:847  const statuses = (jobs ?? []).map((j) => j.status);   // email_scan_jobs
index.ts:850  aggregateStatus = ...completed...
```

But `processConnectionJob` now only fetches the mailbox window and enqueues a **worker** job into a
*different* table, `scan_jobs`, then returns (`index.ts:628`–655). The edge marks its own
`email_scan_jobs` row `completed` the instant that hand-off returns (`index.ts:502`–505). So the
app sees `completed` before the worker has done anything, `isActive` goes false, the app stops
polling, and — because the worker hasn't written candidates (or isn't running at all) —
`pending_count` is 0 and the dashboard shows "nothing to review".

Meanwhile the run's true state lives in `email_scan_runs`: the edge sets it `running`/stage
`reasoning` at hand-off (`index.ts:251`, 617), and the worker finalizes it —
`update email_scan_runs set status='completed', stage = (candidates ? 'review_ready' : 'completed')`
(`worker/src/agent/candidate-bridge.ts:141`–148). The status endpoint simply never consults it for
the aggregate.

## Goals / Non-Goals

**Goals:**
- The app-visible aggregate `status` reflects the worker's real progress: still-active until the
  worker finalizes the run; terminal only when the run is genuinely done.
- A never-processed scan (worker down) resolves to `failed`/`partial`, not a false empty
  `completed`.
- Preserve the endpoint's request/response contract — no iOS change required.
- Preserve the genuine "worker ran and found nothing" case as a correct empty completion.

**Non-Goals:**
- No change to how the worker runs discovery, reconciles, or bridges candidates.
- No DB migration or schema change.
- No change to the fetch/enqueue path (`processConnectionJob`) beyond what status needs.
- App-side hardening (treating `reasoning` as active) is optional defense-in-depth, not the fix.

## Decisions

### D1: Derive the aggregate from `email_scan_runs`, not `email_scan_jobs`

`email_scan_runs` is the single row both writers already own: the edge sets it `failed` on a
fetch-phase error (`index.ts:533`–538) and the worker sets it `completed` on finish. Classify each
run from its `status`:

- `completed` → terminal success (stage `review_ready` or `completed`)
- `failed` → terminal failure
- otherwise (`running` at stage `reasoning`/`fetching`/`queued`) → **active**

Aggregate: all-failed → `failed`; all-terminal with any failure → `partial`; all-terminal, none
failed → `completed`; any active → `running`. `aggregateStage(runs, …)` already reads `run.stage`
and stays as-is. `pending_count` (from `subscription_candidates`) and the true-empty case are
unaffected — a worker that finishes with zero proposals still writes `status='completed'`, so the
app correctly shows "nothing to review" only when discovery actually ran.

- *Alternative — keep `email_scan_jobs`:* rejected; it is the enqueue queue and completes at
  hand-off, which is the bug.
- *Alternative — worker `scan_jobs.status` as the primary signal:* rejected as primary; it doesn't
  capture edge-side fetch failures and carries no candidate/stage detail. Used instead for liveness
  (D2).

### D2: Worker-down timeout via the worker `scan_jobs` queue

An active run must not spin forever when no worker exists. The worker queue distinguishes liveness
precisely (`0001_worker_queue.sql`: `status in ('pending','running','completed','failed')`, plus
`created_at`/`started_at`):

- `pending` = enqueued, **not yet claimed** by any worker
- `running` = **claimed** and in progress (worker alive)

For each still-active run, load its `scan_jobs` row and apply:

- job `running` → worker is alive → keep the run **active** (satisfies "slow-but-alive not
  prematurely failed").
- job `pending` (or no worker row) and `now() - created_at > SCAN_COMPLETION_TIMEOUT` → **worker
  down** → treat the run as `failed` with an error like "scan worker did not pick up the job".
- otherwise → active (still inside the grace window).

`SCAN_COMPLETION_TIMEOUT` defaults to ~5 minutes, read from env so ops can tune it. This adds one
query (`scan_jobs` by `batch_id`/`scan_run_id`) to the status path — cheap, no migration.

- *Alternative — age off `run.started_at` only:* coarser (can't tell a stuck job from a slow-but-
  alive one) and would risk failing a healthy long scan. Kept only as a fallback when no `scan_jobs`
  row is found.

### D3: Fix the per-run `runs[]` mapping too

Today each run card shows `job?.status ?? run.status` with the `email_scan_jobs` row winning
(`index.ts:874`), so per-run cards also read "completed" at hand-off. Switch the per-run `status`
to the run-derived value (same classification as D1, with the D2 timeout applied) so the cards
match the aggregate.

### D4: Write-through the timeout verdict (best-effort)

When D2 declares a run failed, also persist `email_scan_runs.status='failed'` (+ `error_message`,
`completed_at`) best-effort, so the run stops being "running" forever and downstream
notifications/history are consistent. The status response returns `failed` regardless of whether the
write succeeds. (Open question below on whether to keep this transient instead.)

### D5: No contract change, no migration

The JSON shape and field names are unchanged — only the values of `status`/`stage`/`runs[].status`
are computed correctly. iOS, its poll loop, and its models are untouched. Optionally, `isActive`
could also treat stage `reasoning` as active as defense-in-depth, but the server fix covers all
clients and is preferred.

## Risks / Trade-offs

- **Timeout too short prematurely fails a slow worker** → base the failure decision on the
  `scan_jobs` claimed state (a `running` job is never failed by timeout); only unclaimed `pending`
  jobs age out. Default 5 min, env-tunable.
- **Timeout too long makes the user wait on a spinner before seeing failure** → 5 min is a
  reasonable ceiling for fetch + funnel; tune via env if real runs are faster.
- **Worker must actually be running for the happy path** → this change intentionally makes a missing
  worker *visible* (failed) instead of masking it (empty completed). Deploying the worker is a
  prerequisite, not part of this change.
- **Edge `deno` unavailable locally** → the change can only be `deno check`'d and redeployed by the
  user; cover the pure status-derivation logic with a unit-testable helper where practical.
- **Clock/skew** → compare against DB `now()` consistently (the timeout comparison should use the
  database clock, not the edge runtime clock, to avoid skew).

## Migration Plan

1. Refactor `scanStatus` aggregate + per-run derivation (D1, D3); add the `scan_jobs` liveness query
   and timeout helper (D2, D4); read `SCAN_COMPLETION_TIMEOUT` from env with a safe default.
2. Add/extend unit coverage for the status-derivation helper (handoff→running, worker-complete→
   terminal, worker-down→failed, slow-but-alive→running, true-empty→completed).
3. `deno check supabase/functions/email-scan/index.ts` and redeploy the edge function (user; no
   local deno).
4. Ensure the worker is running against the same Postgres, then run the full app→edge→worker→app
   smoke test: a scan should stay "scanning" until the worker finalizes, then show the review queue;
   with the worker stopped, the same scan should end in a "couldn't finish" state after the timeout.

**Rollback:** revert the `scanStatus` change and redeploy the edge function; no data migration to
undo.

## Open Questions

- **Timeout value + source:** confirm 5 minutes and the env var name (`SCAN_COMPLETION_TIMEOUT_MS`?).
- **Transient vs. persisted timeout (D4):** persist `failed` to `email_scan_runs`, or only report it
  in the status response and let a separate reaper own the write? Persisting is simpler for the app
  but adds a write in a read path.
- **Retry affordance:** when a run times out as worker-down, should the app's existing failed-state
  UI already offer "try again", or is a new affordance needed? (Likely reuses the existing failed
  path — confirm.)
