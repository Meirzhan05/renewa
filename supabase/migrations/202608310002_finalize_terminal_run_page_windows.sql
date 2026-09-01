-- Follow-up to 202608310001. When the edge classifier fails a stalled run on a status poll, it marks
-- the run 'failed' but (before this) left its email_scan_jobs page window 'queued'. startScan's reuse
-- guard then keeps handing back that dead batch (observed as an instant reused=True failure), and the
-- stalled reaper skipped it because its loop only touches runs still 'running'.
--
-- This redefines recover_stalled_inbox_scan_runs() to ALSO finalize page windows left queued/running
-- under an already-terminal run, and runs that cleanup once for the rows already in that state. The
-- edge write-through now fails the page window at the source too; this is the durable backstop.

create or replace function public.recover_stalled_inbox_scan_runs(
  p_grace_seconds integer default 720
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
      and not exists (select 1 from public.inbox_agent_executions e where e.scan_run_id = r.id)
      and not exists (select 1 from public.scan_jobs s where s.scan_run_id = r.id)
      and exists (
        select 1 from public.email_scan_jobs j
        where j.scan_run_id = r.id and j.status in ('queued', 'running')
      )
    for update of r skip locked
  loop
    update public.email_scan_runs
      set status = 'failed', stage = 'failed',
          error_message = coalesce(error_message, 'Scan worker is unavailable — please try again shortly.'),
          completed_at = now()
      where id = v_run and status = 'running';
    update public.email_scan_jobs
      set status = 'failed',
          error_message = coalesce(error_message, 'Scan worker was unavailable.')
      where scan_run_id = v_run and status in ('queued', 'running');
    v_count := v_count + 1;
  end loop;

  -- 2) Finalize page windows left queued/running under an already-terminal run (e.g. the edge
  --    classifier failed the run on a poll without touching its window) so the batch is not reused.
  update public.email_scan_jobs j
    set status = 'failed',
        error_message = coalesce(j.error_message, 'Scan run already terminal.')
    where j.status in ('queued', 'running')
      and exists (
        select 1 from public.email_scan_runs r
        where r.id = j.scan_run_id and r.status in ('failed', 'completed', 'cancelled')
      );

  -- 3) Finalize worker jobs orphaned by a deleted parent run so they are never drained or counted.
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

-- One-off: finalize the page windows already stuck queued/running under a terminal run.
update public.email_scan_jobs j
  set status = 'failed',
      error_message = coalesce(j.error_message, 'Scan run already terminal.')
  where j.status in ('queued', 'running')
    and exists (
      select 1 from public.email_scan_runs r
      where r.id = j.scan_run_id and r.status in ('failed', 'completed', 'cancelled')
    );
