## 1. Status-derivation helper (pure, unit-testable)

- [x] 1.1 Add a pure helper that classifies a single run as `active | completed | failed` from
      `email_scan_runs.status` plus its worker `scan_jobs` liveness (`pending`/`running`/terminal)
      and `created_at` vs. a timeout, per design D1/D2 (job `running` → active; job `pending`/absent
      past timeout → failed). — `classifyScanRun` in `_shared/scan-status.ts` (put in `_shared`, not
      `index.ts`, so tests can import it without booting `Deno.serve`).
- [x] 1.2 Add a pure helper that reduces per-run classifications into the aggregate
      `running | partial | completed | failed` (all-failed→failed; all-terminal+any-fail→partial;
      all-terminal→completed; any-active→running). — `aggregateRunStatus`.
- [x] 1.3 Read `SCAN_COMPLETION_TIMEOUT_MS` from env with a safe default (~5 min). — Uses the edge
      clock against the DB `created_at`; sub-second NTP skew is immaterial at 5-min granularity, so
      no extra `now()` round trip (documented inline).

## 2. Wire the helper into `scanStatus`

- [x] 2.1 Load the worker `scan_jobs` rows for the batch (`scan_run_id,status,created_at`) alongside
      the existing `email_scan_runs` query.
- [x] 2.2 Replace the `email_scan_jobs`-based `aggregateStatus` with the D1/D2 helper output.
- [x] 2.3 Replace the per-run `runs[].status = job?.status ?? run.status` mapping with the
      run-derived classification so per-run cards match the aggregate (design D3).
- [x] 2.4 Keep `pending_count`, `candidates`, `aggregateStage`, and the no-batch idle branch
      unchanged; the genuine worker-found-nothing case still reports `completed` with
      `pending_count: 0` (run status is `completed`). `errors` now also surfaces the timeout message.

## 3. Worker-down write-through (design D4)

- [x] 3.1 When a run is classified failed by timeout, best-effort persist
      `email_scan_runs.status='failed'` (+ `stage`, `error_message`, `completed_at`) so it stops
      reporting `running` forever; still return `failed` in the response regardless of the write.

## 4. Tests

- [x] 4.1 Unit tests for the helpers in `_shared/scan-status.test.ts`: handoff → running; worker
      completed (stage review_ready) → completed; worker completed empty → completed; unclaimed job
      past timeout → failed; claimed `running` job past timeout → still active (slow-but-alive);
      missing job past timeout → failed; failed worker job → failed; mixed runs → partial;
      all-failed → failed; env parsing fallbacks.
- [x] 4.2 Aggregate never returns `completed` while any run is active (covered by the handoff →
      running test asserting `aggregateRunStatus(["active"...]) === "running"`).
      NOTE: tests are written but NOT run locally — `deno` is unavailable here; run under task 5.1.

## 5. Ship (ops — user runs; no local deno)

- [ ] 5.1 `deno check supabase/functions/email-scan/index.ts` and redeploy the edge function.
- [ ] 5.2 With the worker running against the same Postgres, run the full app→edge→worker→app smoke
      test: scan stays "scanning" until the worker finalizes, then the review queue appears.
- [ ] 5.3 With the worker stopped, confirm the same scan ends in the app's "couldn't finish" state
      after `SCAN_COMPLETION_TIMEOUT_MS` instead of a false "nothing to review".

## 6. Optional defense-in-depth (app-side)

- [ ] 6.1 (Optional) Treat stage `reasoning` as active in `EmailScanStatus.isActive` /
      presentation so older/edge-lagging clients also keep polling; server fix (D1–D3) is the
      primary remedy.
