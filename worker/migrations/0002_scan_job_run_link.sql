-- Link a queued worker scan job back to the app's scan run + batch, so the worker can write its
-- proposals into the app tables (detected_billing_events → subscription_candidates) against the
-- run the edge function created, and mark that run completed when it finishes. Before this, the
-- worker queue was self-contained (scan_outcomes only) and had no handle on the app-side run.

alter table public.scan_jobs
  add column if not exists scan_run_id uuid,
  add column if not exists batch_id uuid;
