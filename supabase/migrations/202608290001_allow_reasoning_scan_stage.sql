-- The inbox-scan cutover writes email_scan_runs.stage = 'reasoning' when it hands the fetched
-- mailbox window off to the persistent agent worker. The original stage check constraint
-- (202607290001_ai_email_subscription_discovery.sql) predates that stage, so every cutover scan
-- failed at the handoff with:
--   new row for relation "email_scan_runs" violates check constraint "email_scan_runs_stage_check"
-- which threw before the worker job (scan_jobs) could be enqueued -- no worker ever ran, and the app
-- saw the run fail with zero messages. Allow 'reasoning' alongside the existing stages.

alter table public.email_scan_runs
  drop constraint if exists email_scan_runs_stage_check;

alter table public.email_scan_runs
  add constraint email_scan_runs_stage_check
  check (stage in (
    'queued', 'fetching', 'filtering', 'extracting', 'reasoning', 'review_ready', 'completed', 'failed'
  ));
