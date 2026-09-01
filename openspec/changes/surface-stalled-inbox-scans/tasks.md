## 1. Reaper backstop for un-executed runs (D1, D2)

- [x] 1.1 Migration `202608310001_surface_stalled_inbox_scans.sql`: `recover_stalled_inbox_scan_runs()`
      fails an `email_scan_run` that is `running` past the grace with a queued/running page window and
      **zero** downstream (no `inbox_agent_executions`, no `scan_jobs`), then fails its page window(s).
- [x] 1.2 Grace configurable: SQL param `p_grace_seconds` default 720s; edge reads `SCAN_DISPATCH_GRACE_MS`
      (default 12m ≥ the dispatched run TTL of 10m) via `scanDispatchGraceMs`.
- [x] 1.3 Scheduled every minute via pg_cron as `reap-stalled-inbox-scan-runs` (idempotent unschedule/schedule).
- [x] 1.4 DB assertion (rolled back): a stale un-executed run → failed + page window failed; a fresh run
      and a run with a live execution are spared; second pass is idempotent. Ran green against the live
      schema in a rolled-back tx; committed as `supabase/tests/surface_stalled_inbox_scans.sql`.

## 2. Edge: record dispatch outcome, classify the gap (D3, D1)

- [x] 2.1 `processManagedUserJobs` no longer swallows: each `triggerManagedInboxTask` is wrapped, and a
      dispatch failure marks that run `failed` (`failScanRunForReason`, guarded on `status='running'`)
      while remaining connections keep dispatching.
- [x] 2.2 `classifyPaginatedScanRun` fails a run with a queued/running edge page, zero worker jobs, and
      zero executions once past `dispatchGraceMs`; the edge maps it to "Scan worker is unavailable" and
      the existing write-through persists `status='failed'`.
- [x] 2.3 Idempotent: all transitions guard on `status='running'` (edge helper + reaper + write-through).

## 3. Orphaned worker-job cleanup (D5)

- [x] 3.1 Migration: one-off finalize of non-terminal `scan_jobs` whose `scan_run_id` has no
      `email_scan_runs` row (the 49 observed), plus the same sweep inside the recurring reaper.
- [x] 3.2 Status liveness already excludes them: the status worker-job query is batch-scoped, so orphans
      from deleted runs are never counted, and the reaper finalizes them.

## 4. Governance: reconcile deployed branch + env contract (D6)

- [x] 4.1 Merged `codex/unify-tab-transition` (`44f91a4` + follow-ups) into `main` (merge `d9eb522`),
      bringing the deployed managed-dispatch code, migrations `…05/06/07/08`, and `taskVersion=2` onto main.
- [x] 4.2 Documented the environment contract in `worker/README.md`: the edge `TRIGGER_SECRET_KEY`
      environment MUST have a live worker (`trigger deploy` in prod; `trigger:dev` connected in dev) or
      every scan EXPIRES.

## 5. Tests

- [ ] 5.1 Edge unit test that a dispatch error marks the run `failed`. DEFERRED: `email-scan/index.ts`
      exports no test seam (it's a bare `serve()` handler), so this needs a small refactor to extract the
      dispatch/record path. The same failure is covered durably by 5.2 (reaper) and surfaced by 5.3
      (classifier), so behavior is not untested — only the edge-local unit is.
- [x] 5.2 Reaper DB test — see 1.4 (fails stale un-executed run, spares live/fresh, finalizes orphans,
      idempotent).
- [x] 5.3 Classifier tests: runtime-never-materialized past grace → failed; within grace → active; a live
      execution or an in-flight worker job → active; plus `scanDispatchGraceMs` env parsing. 83 edge
      tests green (`deno test supabase/functions/`); `deno check` clean on the edited files.

## 7. Follow-up: dead-batch reuse (found during 6.x verification)

- [x] 7.1 Edge write-through also fails the run's `email_scan_jobs` page window(s) when it fails a run,
      so `startScan`'s reuse guard cannot hand back a dead batch (observed as an instant `reused=True`
      failure when the classifier failed the run but left its window `queued`).
- [x] 7.2 Migration `202608310002`: `recover_stalled_inbox_scan_runs()` also finalizes page windows
      left `queued`/`running` under an already-terminal run; one-off cleanup of the current lingering rows.
- [x] 7.3 DB test extended (a page window under a terminal run is finalized); validated against the live
      schema in a rolled-back tx. `deno check` clean; 83 edge tests green.
- [ ] 7.4 Deploy: `db push` (applies `202608310002` + its one-off) and redeploy the edge. Same op step
      as 6.1 — left for the operator.

## 6. Verification and release  (ops — requires deploy; left for the operator)

- [ ] 6.1 Deploy edge + apply migration `202608310001` (this applies the one-off orphan cleanup and
      schedules the pg_cron backstop).
- [ ] 6.2 With **no** worker connected: start a scan → confirm it reaches `failed` with "Scan worker is
      unavailable" within `SCAN_DISPATCH_GRACE_MS` (not an indefinite `running`/0).
- [ ] 6.3 With a worker live in the edge key's environment: start a scan → confirm `scan-inbox-run`
      goes EXECUTING → COMPLETED and candidates land in `subscription_candidates`.
- [ ] 6.4 Confirm the previously-orphaned `pending` `scan_jobs` are finalized after the migration applies.
