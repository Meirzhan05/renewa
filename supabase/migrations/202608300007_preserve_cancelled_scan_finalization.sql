-- Migration 202608300003 redefined the cumulative-count finalizer after the cancellation-aware
-- version, accidentally restoring failure precedence. A persisted Stop request must win once all
-- pages are drained, while retaining the useful cumulative progress counts.
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
  select * into v_run from public.email_scan_runs where id = p_run_id for update;
  if not found then return false; end if;

  select exists (
    select 1 from public.email_scan_jobs
    where scan_run_id = p_run_id and status in ('queued', 'running')
  ) or exists (
    select 1 from public.scan_jobs
    where scan_run_id = p_run_id and status in ('pending', 'running')
  ) into v_active;
  if v_active then return false; end if;

  select coalesce(sum(coalesce(s.message_count, jsonb_array_length(s.raw_messages))), 0),
         coalesce(sum(s.triage_look_count), 0)
    into v_scanned, v_look
  from public.scan_jobs s where s.scan_run_id = p_run_id;
  select count(*) into v_detected
  from public.detected_billing_events d where d.scan_run_id = p_run_id;

  if v_run.cancel_requested_at is not null then
    update public.email_scan_runs
    set status = 'cancelled', stage = 'cancelled', cancelled_at = coalesce(cancelled_at, now()),
        completed_at = coalesce(completed_at, now()), error_message = null,
        messages_scanned = v_scanned, candidate_messages = v_look, events_detected = v_detected
    where id = p_run_id;
    return true;
  end if;

  select exists (
    select 1 from public.email_scan_jobs where scan_run_id = p_run_id and status = 'failed'
  ) or exists (
    select 1 from public.scan_jobs where scan_run_id = p_run_id and status = 'failed'
  ) into v_failed;
  if v_failed then
    update public.email_scan_runs
    set status = 'failed', stage = 'failed',
        error_message = coalesce(error_message, 'One or more scan pages could not finish.'),
        completed_at = coalesce(completed_at, now()),
        messages_scanned = v_scanned, candidate_messages = v_look, events_detected = v_detected
    where id = p_run_id;
    return true;
  end if;

  select exists (
    select 1 from public.subscription_candidates
    where scan_run_id = p_run_id and review_status = 'pending'
  ) into v_has_candidates;
  update public.email_scan_runs
  set status = 'completed', stage = case when v_has_candidates then 'review_ready' else 'completed' end,
      completed_at = coalesce(completed_at, now()),
      messages_scanned = v_scanned, candidate_messages = v_look, events_detected = v_detected
  where id = p_run_id;
  return true;
end;
$$;

revoke all on function public.finalize_email_scan_run_if_drained(uuid) from public;
grant execute on function public.finalize_email_scan_run_if_drained(uuid) to service_role;
