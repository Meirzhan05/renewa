-- App-visible scan progress must be cumulative across a run's mailbox pages. The historical design
-- overwrote email_scan_runs.messages_scanned / candidate_messages with the MOST RECENT page's count,
-- so a multi-page scan froze at ~one page (verified: 18 pages / 1800 messages reported as 100, and
-- events_detected stuck at 0 for a run that surfaced 6). Record each page's counts on its worker-queue
-- row (scan_jobs) and derive run totals as a SUM over that ledger -- inherently cumulative and
-- idempotent under task retries (a re-run replaces its row, it does not append a new one).

alter table public.scan_jobs
  add column if not exists message_count int,
  add column if not exists triage_look_count int;

-- Per-run progress derived from the page ledger. Kept in SQL so message payloads never transfer on a
-- status poll. `message_count` falls back to the length of the stored window for rows created before
-- this migration (no backfill needed). `likely_billing` is the cumulative Tier-1 triage "look" set;
-- it reads 0 until worker pages start recording it, which is honest rather than the previous
-- misleading "every fetched message is likely-billing". `detected` counts the run's surfaced evidence.
create or replace function public.email_scan_batch_progress(p_user_id uuid, p_batch_id uuid)
returns table (
  scan_run_id uuid,
  messages_scanned bigint,
  likely_billing bigint,
  detected bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select r.id as scan_run_id,
    coalesce((
      select sum(coalesce(s.message_count, jsonb_array_length(s.raw_messages)))
      from public.scan_jobs s where s.scan_run_id = r.id
    ), 0) as messages_scanned,
    coalesce((
      select sum(s.triage_look_count)
      from public.scan_jobs s where s.scan_run_id = r.id
    ), 0) as likely_billing,
    coalesce((
      select count(*)
      from public.detected_billing_events d where d.scan_run_id = r.id
    ), 0) as detected
  from public.email_scan_runs r
  where r.user_id = p_user_id and r.batch_id = p_batch_id;
$$;

revoke all on function public.email_scan_batch_progress(uuid, uuid) from public;
grant execute on function public.email_scan_batch_progress(uuid, uuid) to service_role;

-- Redefine the drain finalizer (from 202608300001) to also denormalize the cumulative counts onto the
-- run when it reaches a terminal state, so history/insights/notifications that read email_scan_runs
-- directly (e.g. insights-refresh reads events_detected) stay consistent with the live status endpoint.
-- Completion semantics are otherwise unchanged.
create or replace function public.finalize_email_scan_run_if_drained(p_run_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_run public.email_scan_runs%rowtype;
  v_active boolean;
  v_failed boolean;
  v_has_candidates boolean;
  v_scanned bigint;
  v_look bigint;
  v_detected bigint;
begin
  select * into v_run
  from public.email_scan_runs
  where id = p_run_id
  for update;

  if not found then return false; end if;

  select exists (
    select 1 from public.email_scan_jobs
    where scan_run_id = p_run_id and status in ('queued', 'running')
  ) or exists (
    select 1 from public.scan_jobs
    where scan_run_id = p_run_id and status in ('pending', 'running')
  ) into v_active;
  if v_active then return false; end if;

  -- Cumulative page-ledger totals for the drained run (same derivation as email_scan_batch_progress).
  select coalesce(sum(coalesce(s.message_count, jsonb_array_length(s.raw_messages))), 0),
         coalesce(sum(s.triage_look_count), 0)
    into v_scanned, v_look
  from public.scan_jobs s where s.scan_run_id = p_run_id;
  select count(*) into v_detected
  from public.detected_billing_events d where d.scan_run_id = p_run_id;

  select exists (
    select 1 from public.email_scan_jobs
    where scan_run_id = p_run_id and status = 'failed'
  ) or exists (
    select 1 from public.scan_jobs
    where scan_run_id = p_run_id and status = 'failed'
  ) into v_failed;

  if v_failed then
    update public.email_scan_runs
    set status = 'failed', stage = 'failed',
        error_message = coalesce(error_message, 'One or more scan pages could not finish.'),
        completed_at = coalesce(completed_at, now()),
        messages_scanned = v_scanned,
        candidate_messages = v_look,
        events_detected = v_detected
    where id = p_run_id;
    return true;
  end if;

  select exists (
    select 1 from public.subscription_candidates
    where scan_run_id = p_run_id and review_status = 'pending'
  ) into v_has_candidates;

  update public.email_scan_runs
  set status = 'completed',
      stage = case when v_has_candidates then 'review_ready' else 'completed' end,
      completed_at = coalesce(completed_at, now()),
      messages_scanned = v_scanned,
      candidate_messages = v_look,
      events_detected = v_detected
  where id = p_run_id;
  return true;
end;
$$;

revoke all on function public.finalize_email_scan_run_if_drained(uuid) from public;
grant execute on function public.finalize_email_scan_run_if_drained(uuid) to service_role;
