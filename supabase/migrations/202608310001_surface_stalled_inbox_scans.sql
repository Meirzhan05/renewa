-- Surface inbox scans that can never progress instead of hanging at "0 discoveries" forever.
--
-- Gap this closes: recover_expired_inbox_agent_executions() only acts on inbox_agent_executions rows
-- that EXIST. When the dispatched `scan-inbox-run` runtime task never materializes (it EXPIRES in the
-- task runtime because no worker is connected in the edge key's environment), NO execution is ever
-- created: the run stays 'running', the edge page window (email_scan_jobs) stays 'queued', and nothing
-- fails it. The app only advances on a successful poll, so the user sees 0 with no error, forever.
--
-- This adds a run-level backstop (mirrors the edge classifier's gate: a still-'running' run past the
-- dispatch grace with a queued/running page window and NOTHING downstream -> failed) plus a cleanup
-- for worker jobs orphaned by deleted runs, and schedules the backstop every minute via pg_cron.

create or replace function public.recover_stalled_inbox_scan_runs(
  p_grace_seconds integer default 720 -- >= the dispatched run TTL (10m) so a valid queued run is not failed early
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_run uuid;
  v_count integer := 0;
begin
  -- 1) Fail runs whose dispatched runtime task never materialized.
  for v_run in
    select r.id
    from public.email_scan_runs r
    where r.status = 'running'
      and r.started_at <= now() - make_interval(secs => greatest(p_grace_seconds, 60))
      -- nothing downstream exists: the runtime task never ran
      and not exists (select 1 from public.inbox_agent_executions e where e.scan_run_id = r.id)
      and not exists (select 1 from public.scan_jobs s where s.scan_run_id = r.id)
      -- but a real, un-advanced page window is still waiting
      and exists (
        select 1 from public.email_scan_jobs j
        where j.scan_run_id = r.id and j.status in ('queued', 'running')
      )
    for update of r skip locked
  loop
    update public.email_scan_runs
      set status = 'failed',
          stage = 'failed',
          error_message = coalesce(error_message, 'Scan worker is unavailable — please try again shortly.'),
          completed_at = now()
      where id = v_run and status = 'running';
    -- Fail the un-processed page window(s) so status liveness stays consistent with the run.
    update public.email_scan_jobs
      set status = 'failed',
          error_message = coalesce(error_message, 'Scan worker was unavailable.')
      where scan_run_id = v_run and status in ('queued', 'running');
    v_count := v_count + 1;
  end loop;

  -- 2) Finalize worker jobs orphaned by a deleted parent run so they are never drained or counted.
  update public.scan_jobs s
    set status = 'failed',
        finished_at = now(),
        error = coalesce(s.error, 'Parent scan run no longer exists.')
    where s.status in ('pending', 'running')
      and not exists (select 1 from public.email_scan_runs r where r.id = s.scan_run_id);

  return v_count;
end;
$$;

revoke all on function public.recover_stalled_inbox_scan_runs(integer) from public;
grant execute on function public.recover_stalled_inbox_scan_runs(integer) to service_role;

-- One-off, reversible cleanup of the worker jobs already orphaned by deleted runs (49 observed).
-- Reversible: these rows carry their own payload, so a mistaken sweep can be reset to 'pending'.
update public.scan_jobs s
  set status = 'failed',
      finished_at = now(),
      error = coalesce(s.error, 'Parent scan run no longer exists.')
  where s.status in ('pending', 'running')
    and not exists (select 1 from public.email_scan_runs r where r.id = s.scan_run_id);

-- Run the backstop every minute (pg_cron). Idempotent: replace any prior schedule of the same name.
do $$
begin
  if exists (select 1 from cron.job where jobname = 'reap-stalled-inbox-scan-runs') then
    perform cron.unschedule('reap-stalled-inbox-scan-runs');
  end if;
  perform cron.schedule(
    'reap-stalled-inbox-scan-runs',
    '* * * * *',
    $cron$select public.recover_stalled_inbox_scan_runs();$cron$
  );
end $$;
