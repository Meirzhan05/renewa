## Why

The app's "N emails checked" counter reflects how many emails `scan-inbox-run` **fetched and enqueued**, not how many the `analyze-inbox-page` agents have actually **processed**. Because `scan_jobs.message_count` is written when a page row is created, and `email_scan_batch_progress` sums it over *all* rows regardless of status, the counter jumps to the full inbox size within the ~4 minutes it takes to paginate, then sits frozen there for the 20+ minutes the agents spend reasoning. Verified on a live 3,000-email run: UI showed **3000** while the agents had checked **1800**.

## What Changes

- `email_scan_batch_progress.messages_scanned` sums `message_count` only over pages the agents have finished (`scan_jobs.status = 'completed'`), so the live counter climbs in step with real processing (100 → 200 → … → 3000) instead of jumping to the enqueued total.
- `finalize_email_scan_run_if_drained` applies the same completed-only filter to the `messages_scanned` value it denormalizes onto `email_scan_runs`, so the persisted history figure matches the live status endpoint.
- No change to the API shape or the app: the `scanned` field the client already reads simply carries the correct (processed) number. The "X of Y checked" progress-bar idea (numerator = completed sum, denominator = all-rows sum) is noted as a possible follow-up, not part of this change.

## Capabilities

### New Capabilities
- `scan-progress-reporting`: how a running mailbox scan reports app-visible progress ("emails checked") so the number reflects emails the analysis agents have processed, not emails the fetcher enqueued.

### Modified Capabilities
<!-- None: there are no existing committed specs; this behavior lived only in migration SQL. -->

## Impact

- New migration redefining `public.email_scan_batch_progress(uuid, uuid)` and `public.finalize_email_scan_run_if_drained(uuid)` — both currently defined in `supabase/migrations/202608300003_scan_job_page_counts.sql` (finalize later touched by `202608300007`).
- No app/Swift code change; `supabase/functions/_shared/scan-status.ts` and `email-scan/index.ts` continue to consume the same RPC and field.
- `likely_billing`/`detected` semantics are unchanged (`triage_look_count` is only set as a page is analyzed, so it already tracks agent progress).
- Behavior at completion is unchanged (all pages terminal → sum equals the successfully-processed total); the difference is only *during* a scan and for runs with failed pages (which then honestly report < full inbox).
