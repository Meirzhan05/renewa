alter table public.email_scan_jobs
  drop constraint email_scan_jobs_scan_run_id_key,
  add column page_number integer not null default 1 check (page_number > 0),
  add column provider_continuation text;

create unique index email_scan_jobs_run_page_idx
  on public.email_scan_jobs (scan_run_id, page_number);
