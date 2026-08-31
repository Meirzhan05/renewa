-- A Stop request cancels queued work immediately and lets a live page finish its atomic write.
-- If its worker has already died, however, a `scan_jobs` row can remain `running` without any
-- leased/running execution to perform that boundary. Treat that orphan as cancelled work so the
-- durable finalizer can resolve the run without discarding completed discoveries.
create or replace function public.cancel_email_scan_run(p_user_id uuid, p_run_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.email_scan_runs
  set cancel_requested_at = coalesce(cancel_requested_at, now()), status = 'running', stage = 'reasoning'
  where id = p_run_id and user_id = p_user_id and status = 'running';
  if not found then return false; end if;

  update public.inbox_agent_executions
  set state = 'cancelled', completed_at = now(), lease_expires_at = null, dispatch_expires_at = null
  where scan_run_id = p_run_id and state in ('queued', 'leased', 'retryable');

  update public.email_scan_jobs
  set status = 'failed', error_message = 'Scan cancelled by user.', completed_at = now()
  where scan_run_id = p_run_id and status = 'queued';

  update public.scan_jobs s
  set status = 'failed', error = 'Scan cancelled by user.', finished_at = now()
  where s.scan_run_id = p_run_id
    and (
      s.status = 'pending'
      or (
        s.status = 'running'
        and not exists (
          select 1 from public.inbox_agent_executions e
          where e.scan_job_id = s.id and e.state in ('leased', 'running')
        )
      )
    );

  perform public.finalize_email_scan_run_if_drained(p_run_id);
  return true;
end;
$$;

revoke all on function public.cancel_email_scan_run(uuid, uuid) from public;
grant execute on function public.cancel_email_scan_run(uuid, uuid) to service_role;
