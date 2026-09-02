## 1. Migration: count completed pages only

- [x] 1.1 Added `supabase/migrations/202609010001_count_checked_by_completed_pages.sql`.
- [x] 1.2 `create or replace public.email_scan_batch_progress(uuid, uuid)` copied from `202608300003`, added `filter (where s.status = 'completed')` to the `messages_scanned` sum only (`likely_billing`/`detected` and the `coalesce(message_count, jsonb_array_length(raw_messages))` fallback unchanged). Re-issued `revoke`/`grant`.
- [x] 1.3 `create or replace public.finalize_email_scan_run_if_drained(uuid)` copied verbatim from the latest definition (`202608300007`, cancellation-aware), added the same completed-only `filter` to the `v_scanned` sum only. Cancel-wins precedence, failed/completed branches, and `v_look`/`v_detected` unchanged. Re-issued `revoke`/`grant`.

## 2. Validate against the live schema (read-only)

- [x] 2.1 In `BEGIN … ROLLBACK`, applied both functions and seeded a mixed-status run (2 completed + running + pending + failed); asserted `messages_scanned` = 200 (completed-only, not 500 all-rows), `likely_billing` = 14 and `detected` = 0 unchanged. Passed.
- [x] 2.2 Same rolled-back tx: drained a failed run → `finalize` denormalized `messages_scanned` = 200 (not 300); a cancel-requested run → status `cancelled` (cancel wins) with `messages_scanned` = 100. Passed.

## 3. Regression test

- [x] 3.1 Added `supabase/tests/count_checked_by_completed_pages.sql` (self-contained `auth.users` fixture, begin/do/rollback). Asserts counter = completed-only; all-completed → full inbox (300); some-failed → less than full (200 < 300); cancel precedence. Dry-ran against live schema with the migration applied + rolled back: "all assertions passed".
- [x] 3.2 `deno test supabase/functions/_shared/scan-status.test.ts` → 27 passed, 0 failed (RPC output shape unchanged).

## 4. Apply + verify (production deploy — user's step)

- [ ] 4.1 `supabase db push` to apply the migration. NOTE: this also applies the not-yet-deployed `202608310003_terminalize_inbox_analysis.sql` — expected, but be aware it ships in the same push.
- [ ] 4.2 On the next (or in-flight) multi-page scan, confirm "emails checked" climbs with page completions rather than jumping to the enqueued total; a run with a failed page reports < full inbox. (Because `email_scan_batch_progress` is computed live per poll, the in-flight run's counter corrects on the next poll after the push.)
