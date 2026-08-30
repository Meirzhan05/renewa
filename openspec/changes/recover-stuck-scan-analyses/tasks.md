## 1. Bound the page analysis (prevention)

- [ ] 1.1 Add a timeout around the model/LLM calls (and an overall per-page deadline) in
      `worker/src/managed/page-analysis.ts` — on timeout, throw so trigger.dev's native retry applies.
      Budgets configurable via env with sensible defaults (e.g. per-call ~90s, per-page ~5m).
- [ ] 1.2 Lower the `analyze-inbox-page` task `maxDuration` from 3600s to ~600s (keep the run
      orchestrator's duration generous enough for a full scan).
- [ ] 1.3 Worker tests: a page whose model call exceeds the timeout rejects (fails) rather than hangs.

## 2. Recovery unblocks the run

- [ ] 2.1 Migration: redefine `recover_expired_inbox_agent_executions()` so that, when it marks an
      execution `failed` past the retry cap, it also fails the linked `scan_jobs` row (via
      `scan_job_id`) and calls `finalize_email_scan_run_if_drained(scan_run_id)` in the same
      transaction. Retryable executions are left for native retry.
- [ ] 2.2 DB assertions (rolled back): an expired-lease running execution past the cap → execution
      failed + its scan_jobs failed + run finalized; a live (unexpired) execution is untouched; repeated
      calls do not double-finalize.

## 3. Schedule the reaper

- [ ] 3.1 Decide pg_cron vs edge-cron (is pg_cron enabled on the project?).
- [ ] 3.2a If pg_cron: schedule `recover_expired_inbox_agent_executions()` every ~60–90s in a migration.
- [ ] 3.2b Else: add an authenticated `reap` edge action (mirroring `automatic`/`renew_monitoring`) that
      calls the recovery routine, and drive it from the existing monitor schedule.
- [ ] 3.3 Verify the schedule actually fires and reclaims a seeded expired execution.

## 4. Verification and release

- [ ] 4.1 Worker typecheck + tests; edge `deno check` (+ tests if the edge action is added).
- [ ] 4.2 End-to-end: simulate a stuck page (kill / force a lease expiry) and confirm the run reaches a
      terminal state within a couple of minutes with the other pages' candidates intact — no manual DB
      surgery.
- [ ] 4.3 Deploy: migration + trigger.dev worker (+ edge if the `reap` action is used).
