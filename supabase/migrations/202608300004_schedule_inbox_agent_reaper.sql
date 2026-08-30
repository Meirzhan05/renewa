-- A managed page-analysis task can die abruptly (killed at maxDuration, crashed, OOM) after skipping
-- its own cleanup, leaving its inbox_agent_executions row and scan_jobs row stuck 'running' with an
-- expired lease. recover_expired_inbox_agent_executions() reclaimed the execution but stopped there --
-- it never failed the linked page or finalized the run, and nothing scheduled it. So one dead task
-- wedged the whole scan at 'running' forever (observed: run stuck ~104 min, unstuck by hand).
--
-- This redefines the reaper to ALSO fail the linked scan_jobs and finalize the run on give-up, and
-- schedules it via pg_cron so recovery is automatic. Prevention (a per-model-call timeout + a lower
-- page maxDuration) lives in the worker.

create or replace function public.recover_expired_inbox_agent_executions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
  v_runs uuid[];
  v_run uuid;
begin
  -- Give up on an expired execution once native retries are exhausted (attempt_count >= 3) or the
  -- lease has been dead long enough that no task is plausibly still retrying (a hard backstop that
  -- guarantees the run cannot stay 'running' forever). Otherwise return it to 'retryable'.
  with expired as (
    select e.id, e.scan_job_id, e.scan_run_id,
      (e.attempt_count >= 3 or e.lease_expires_at <= now() - interval '10 minutes') as gave_up
    from public.inbox_agent_executions e
    where e.state = 'running' and e.lease_expires_at <= now()
  ),
  reclaimed as (
    update public.inbox_agent_executions e
    set state = case when x.gave_up then 'failed'::public.inbox_agent_execution_state
                     else 'retryable'::public.inbox_agent_execution_state end,
        available_at = now(),
        lease_expires_at = null,
        completed_at = case when x.gave_up then now() else e.completed_at end,
        last_error = coalesce(e.last_error, 'Agent execution lease expired.')
    from expired x
    where e.id = x.id and e.state = 'running'
    returning e.id
  ),
  failed_jobs as (
    update public.scan_jobs s
    set status = 'failed',
        error = coalesce(s.error, 'Agent execution lease expired; page could not finish.'),
        finished_at = now()
    from expired x
    where x.gave_up and x.scan_job_id is not null
      and s.id = x.scan_job_id and s.status in ('pending', 'running')
    returning s.scan_run_id
  )
  select
    (select count(*) from reclaimed),
    (select coalesce(array_agg(distinct scan_run_id) filter (where scan_run_id is not null),
                     array[]::uuid[])
     from failed_jobs)
  into v_count, v_runs;

  -- Finalize each run a give-up just drained (idempotent; no-op while any page still runs).
  foreach v_run in array coalesce(v_runs, array[]::uuid[]) loop
    perform public.finalize_email_scan_run_if_drained(v_run);
  end loop;

  return v_count;
end;
$$;

revoke all on function public.recover_expired_inbox_agent_executions() from public;
grant execute on function public.recover_expired_inbox_agent_executions() to service_role;

-- Run the reaper every minute (pg_cron). Idempotent: replace any prior schedule of the same name.
do $$
begin
  if exists (select 1 from cron.job where jobname = 'reap-inbox-agent-executions') then
    perform cron.unschedule('reap-inbox-agent-executions');
  end if;
  perform cron.schedule(
    'reap-inbox-agent-executions',
    '* * * * *',
    $cron$select public.recover_expired_inbox_agent_executions();$cron$
  );
end $$;
