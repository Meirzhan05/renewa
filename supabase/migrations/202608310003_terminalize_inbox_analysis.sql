-- Terminalize managed page analysis so a failing page cannot loop forever.
--
-- Before this, analyze-inbox-page completed every failure as 'retryable' with no cap, and
-- complete_inbox_agent_execution neither capped retries nor finalized the run on 'failed'. A permanent
-- error (e.g. DeepSeek "Insufficient Balance") therefore re-dispatched every minute for 13+ hours while
-- the run stayed "running". The worker now fails permanent provider errors terminally; this adds the
-- database-side backstops: cap retries and finalize the run whenever an execution ends 'failed'.

-- 1) complete_inbox_agent_execution: cap 'retryable' at dispatch_attempt >= 3 (-> 'failed'), and when an
--    execution ends 'failed', fail its page and finalize the run. Signature unchanged (3 args).
create or replace function public.complete_inbox_agent_execution(
  p_execution_id uuid,
  p_state public.inbox_agent_execution_state,
  p_error text default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.inbox_agent_executions%rowtype;
  v_state public.inbox_agent_execution_state;
  v_updated boolean;
begin
  if p_state not in ('completed', 'failed', 'cancelled', 'retryable') then
    raise exception 'invalid terminal execution state';
  end if;

  select * into v_row from public.inbox_agent_executions where id = p_execution_id;
  if not found then return false; end if;

  -- Cap retries: once the dispatch budget is spent, a 'retryable' completion becomes terminal 'failed'
  -- so a page that keeps failing cannot loop under the dispatcher forever.
  v_state := p_state;
  if p_state = 'retryable' and coalesce(v_row.dispatch_attempt, 0) >= 3 then
    v_state := 'failed';
  end if;

  update public.inbox_agent_executions
  set state = v_state,
      last_error = left(p_error, 500),
      lease_expires_at = null,
      completed_at = case when v_state in ('completed', 'failed', 'cancelled') then now() else null end,
      available_at = case when v_state = 'retryable'
        then now() + make_interval(secs => least(300, greatest(3, attempt_count * attempt_count * 3)))
        else available_at end
  where id = p_execution_id and state not in ('completed', 'failed', 'cancelled');
  v_updated := found;

  -- A failed execution fails its page and finalizes the run, so a dead page never leaves the run
  -- reporting in-progress. Idempotent: guarded on non-terminal job state; finalize is drain-checked.
  if v_updated and v_state = 'failed' then
    update public.scan_jobs
      set status = 'failed', finished_at = now(),
          error = coalesce(error, left(p_error, 500), 'Managed page analysis failed.')
      where id = v_row.scan_job_id and status in ('pending', 'running');
    perform public.finalize_email_scan_run_if_drained(v_row.scan_run_id);
  end if;

  return v_updated;
end;
$$;

-- 2) Backstop reaper: fail 'retryable' executions whose dispatch budget is spent (>= 3) -- e.g. a worker
--    that died before completing terminally -- fail their page, and finalize the run. Runs via pg_cron.
create or replace function public.recover_exhausted_inbox_agent_retries()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_runs uuid[];
  v_run uuid;
  v_count integer := 0;
begin
  with failed_exec as (
    update public.inbox_agent_executions e
    set state = 'failed', completed_at = now(), lease_expires_at = null,
        last_error = coalesce(e.last_error, 'Managed page analysis exhausted its retry budget.')
    where e.state = 'retryable' and coalesce(e.dispatch_attempt, 0) >= 3
    returning e.scan_job_id, e.scan_run_id
  ),
  failed_jobs as (
    update public.scan_jobs s
    set status = 'failed', finished_at = now(),
        error = coalesce(s.error, 'Managed page analysis exhausted its retry budget.')
    from failed_exec fe
    where s.id = fe.scan_job_id and s.status in ('pending', 'running')
    returning s.id
  )
  select
    (select count(*) from failed_exec),
    (select coalesce(array_agg(distinct scan_run_id) filter (where scan_run_id is not null),
                     array[]::uuid[]) from failed_exec)
  into v_count, v_runs;

  foreach v_run in array coalesce(v_runs, array[]::uuid[]) loop
    perform public.finalize_email_scan_run_if_drained(v_run);
  end loop;

  return v_count;
end;
$$;

revoke all on function public.recover_exhausted_inbox_agent_retries() from public;
grant execute on function public.recover_exhausted_inbox_agent_retries() to service_role;

-- Run the backstop every minute (idempotent unschedule/schedule).
do $$
begin
  if exists (select 1 from cron.job where jobname = 'reap-exhausted-inbox-agent-retries') then
    perform cron.unschedule('reap-exhausted-inbox-agent-retries');
  end if;
  perform cron.schedule(
    'reap-exhausted-inbox-agent-retries',
    '* * * * *',
    $cron$select public.recover_exhausted_inbox_agent_retries();$cron$
  );
end $$;
