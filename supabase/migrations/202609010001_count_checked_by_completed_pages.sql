-- App-visible "emails checked" must count emails the analysis agents have PROCESSED, not emails the
-- fetcher (scan-inbox-run) enqueued. scan_jobs.message_count is written when a page row is CREATED,
-- and 202608300003 summed it over ALL rows regardless of status. Because pagination enqueues every
-- page in a few minutes while analyze-inbox-page reasons over them for far longer, the counter jumped
-- to the full inbox size immediately and then sat frozen (observed: a 3000-email run reported 3000
-- while only 1800 had actually been checked). This filters the messages_scanned sum to completed
-- pages only, so the number climbs with real agent progress. likely_billing/detected are unchanged:
-- triage_look_count is written by the agent during analysis, so pending pages already contribute 0.
--
-- Read-side only: same RPC/field the app already consumes; no data backfill. Both functions are copied
-- verbatim from their latest definitions (email_scan_batch_progress from 202608300003;
-- finalize_email_scan_run_if_drained from the cancellation-aware 202608300007) with only the
-- messages_scanned sum gaining `filter (where s.status = 'completed')`.

-- 1) Live status poll: cumulative per-run progress from the page ledger.
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
        filter (where s.status = 'completed')
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

-- 2) Drain finalizer: denormalize the same completed-only messages_scanned onto the run at terminal
--    state, so history and the live counter never disagree. Cancel-wins precedence and every other
--    branch are byte-for-byte from 202608300007; only v_scanned gains the completed-only filter.
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

  select coalesce(sum(coalesce(s.message_count, jsonb_array_length(s.raw_messages)))
                    filter (where s.status = 'completed'), 0),
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
