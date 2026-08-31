-- Qualify the output columns in the PL/pgSQL RETURN QUERY and keep a user at its exact active-work
-- ceiling from receiving another page. This replaces the initially deployed reservation function.
create or replace function public.reserve_inbox_agent_executions(
  p_limit integer,
  p_global_limit integer,
  p_google_limit integer,
  p_microsoft_limit integer,
  p_per_user_limit integer default 1,
  p_lease_seconds integer default 120
)
returns table (execution_id uuid, scan_run_id uuid, scan_job_id uuid, dispatch_token uuid)
language plpgsql security definer set search_path = public as $$
declare v_slots integer;
begin
  if p_limit < 1 or p_global_limit < 1 or p_google_limit < 1 or p_microsoft_limit < 1
     or p_per_user_limit < 1 or p_lease_seconds < 30 or p_lease_seconds > 900 then
    raise exception 'invalid inbox dispatch capacity';
  end if;
  select greatest(0, p_global_limit - count(*)::integer) into v_slots
  from public.inbox_agent_executions where state in ('leased', 'running');
  v_slots := least(p_limit, v_slots);
  if v_slots = 0 then return; end if;

  return query
  with active_user as (
    select user_id, count(*)::integer as active_count from public.inbox_agent_executions
    where state in ('leased', 'running') group by user_id
  ), active_provider as (
    select j.provider, count(*)::integer as active_count from public.inbox_agent_executions e
    join public.scan_jobs j on j.id = e.scan_job_id
    where e.state in ('leased', 'running') group by j.provider
  ), eligible as materialized (
    select e.id, e.scan_run_id, e.scan_job_id, e.user_id, j.provider, e.available_at, e.created_at,
      row_number() over (partition by e.user_id order by e.available_at, e.created_at) as user_rank,
      row_number() over (partition by j.provider order by e.available_at, e.created_at) as provider_rank,
      coalesce(au.active_count, 0) as user_active,
      coalesce(ap.active_count, 0) as provider_active
    from public.inbox_agent_executions e
    join public.email_scan_runs r on r.id = e.scan_run_id
    join public.scan_jobs j on j.id = e.scan_job_id
    left join active_user au on au.user_id = e.user_id
    left join active_provider ap on ap.provider = j.provider
    where e.task_kind = 'page_analysis' and e.state in ('queued', 'retryable')
      and e.available_at <= now() and r.cancel_requested_at is null
  ), selected as (
    select * from eligible
    where user_rank <= greatest(0, p_per_user_limit - user_active)
      and provider_rank <= case provider when 'google' then greatest(0, p_google_limit - provider_active)
                                          when 'microsoft' then greatest(0, p_microsoft_limit - provider_active)
                                          else 0 end
    order by user_rank, available_at nulls first, id
    limit v_slots
  ), locked as (
    select e.id
    from public.inbox_agent_executions e
    join selected s on s.id = e.id
    where e.state in ('queued', 'retryable')
    for update of e skip locked
  ), claimed as (
    update public.inbox_agent_executions e
    set state = 'leased', dispatch_token = gen_random_uuid(), dispatch_attempt = e.dispatch_attempt + 1,
        dispatch_expires_at = now() + make_interval(secs => p_lease_seconds),
        leased_at = now(), lease_expires_at = now() + make_interval(secs => p_lease_seconds),
        runtime_task_id = null, last_error = null
    from locked s
    where e.id = s.id and e.state in ('queued', 'retryable')
    returning e.id, e.scan_run_id, e.scan_job_id, e.dispatch_token
  ) select c.id, c.scan_run_id, c.scan_job_id, c.dispatch_token from claimed c;
end $$;

revoke all on function public.reserve_inbox_agent_executions(integer, integer, integer, integer, integer, integer) from public;
grant execute on function public.reserve_inbox_agent_executions(integer, integer, integer, integer, integer, integer) to service_role;
