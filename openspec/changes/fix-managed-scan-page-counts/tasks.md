## 1. Per-page ledger schema

- [x] 1.1 Add an idempotent migration: `scan_jobs.message_count int` (nullable) and
      `scan_jobs.triage_look_count int` (nullable). No backfill; `add column if not exists`.
      (`supabase/migrations/202608300003_scan_job_page_counts.sql`)
- [x] 1.2 Verify the migration applies against the real schema — done via a rolled-back transaction
      (`begin; \i migration; … rollback;`) since this environment has no local Supabase stack; both
      columns and the two functions create cleanly. Full `supabase db reset` deferred to deploy (5.3).

## 2. Edge: record and aggregate the ledger

- [x] 2.1 In `processConnectionJob` (`email-scan/index.ts`), set `message_count` on the enqueued
      `scan_jobs` page row from `providerBatch.metadata.length`.
- [x] 2.2 Replace the app-visible progress derivation so, per run, `scanned` =
      `SUM(coalesce(message_count, jsonb_array_length(raw_messages)))` over the run's `scan_jobs`,
      aggregated in SQL (`email_scan_batch_progress` RPC; payloads never selected into JS).
- [x] 2.3 Derive `detected` per run as the count of the run's surfaced evidence
      (`detected_billing_events`).
- [x] 2.4 Derive `candidate_messages` per run as `SUM(triage_look_count)`; reads 0 until pages record
      it (honest) rather than mirroring the fetched count.
- [x] 2.5 Update the aggregate fields (`scanned`/`candidate_messages`/`detected`) and the per-run
      `runs[]` entries to use these ledger aggregates via shared `indexRunProgress`/`totalRunProgress`
      helpers; response shape unchanged.
- [x] 2.6 Denormalize the computed totals onto `email_scan_runs` at finalize time (in
      `finalize_email_scan_run_if_drained`) so history/insights/notifications that read the run row
      stay consistent with the live status endpoint.

## 3. Worker: record the triage look count per page

- [x] 3.1 In `analyzeInboxPage` (`worker/src/managed/page-analysis.ts`), capture the `triage` result
      that `runTwoTierScan` returns and surface its look count (`PageAnalysis`).
- [x] 3.2 In the page task (`worker/src/trigger/analyze-inbox-page.ts`) and the legacy loop
      (`worker/src/worker.ts`), persist the page's `triage_look_count` on its `scan_jobs` row via the
      idempotent `recordPageTriageCount` helper.

## 4. Tests

- [x] 4.1 Pure edge tests: `indexRunProgress`/`totalRunProgress` coerce bigint-as-string and sum
      correctly (`_shared/scan-status.test.ts`).
- [x] 4.2 SQL assertion on the real 18-page run (rolled back): `email_scan_batch_progress` returns
      1800 via the `raw_messages` fallback (null `message_count`) and again via the populated column,
      `detected` = 6, and the ledger is one distinct row per page (no double-count).
- [x] 4.3 Edge test: batch with two connections/runs sums across both runs.
- [x] 4.4 Worker test: `recordPageTriageCount` issues an idempotent `SET` keyed by the page id
      (`worker/test/page-analysis.test.ts`).

## 5. Verification and release

- [x] 5.1 Run worker typecheck (clean) + tests (96 pass) and the Edge `deno check` (clean) / tests
      (41 pass).
- [ ] 5.2 On a multi-page scan (local or the hosted project), confirm `scanned` climbs page by page and
      the final totals match the ledger (`SUM(message_count)`), `detected` matches surfaced candidates,
      and the app shows an increasing "messages checked" during the scan.
- [ ] 5.3 Deploy the migration + updated `email-scan` Function + trigger.dev worker build to the hosted
      project; re-run a 2+-page scan and confirm progress is cumulative end to end.
