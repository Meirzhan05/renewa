-- Durable, database-led dispatch for managed Inbox page analyses. Trigger.dev is the runtime, while
-- this ledger owns admission and retry so a worker restart cannot strand work.
alter table public.inbox_agent_executions
  add column if not exists dispatch_token uuid,
  add column if not exists dispatch_expires_at timestamptz,
  add column if not exists dispatch_attempt integer not null default 0;

create index if not exists inbox_agent_executions_dispatch_idx
  on public.inbox_agent_executions (state, available_at, created_at)
  where state in ('queued', 'retryable');
create index if not exists inbox_agent_executions_active_capacity_idx
  on public.inbox_agent_executions (state, user_id, created_at)
  where state in ('leased', 'running');

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
    where user_rank <= greatest(1, p_per_user_limit - user_active)
      and provider_rank <= case provider when 'google' then greatest(0, p_google_limit - provider_active)
                                          when 'microsoft' then greatest(0, p_microsoft_limit - provider_active)
                                          else 0 end
    order by user_rank, available_at nulls first, id
    limit v_slots
  ), locked as (
    -- Lock only the final fair selection. Windows cannot be locked directly,
    -- but this outer base-table lock safely skips rows a competing dispatcher won.
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
  ) select id, scan_run_id, scan_job_id, dispatch_token from claimed;
end $$;

create or replace function public.attach_inbox_agent_runtime(
  p_execution_id uuid, p_dispatch_token uuid, p_runtime_task_id text
) returns boolean language sql security definer set search_path = public as $$
  update public.inbox_agent_executions set runtime_task_id = p_runtime_task_id
  where id = p_execution_id and state = 'leased' and dispatch_token = p_dispatch_token
    and dispatch_expires_at > now() returning true;
$$;

create or replace function public.claim_dispatched_inbox_agent_execution(
  p_execution_id uuid, p_dispatch_token uuid, p_runtime_task_id text, p_lease_seconds integer default 120
) returns boolean language plpgsql security definer set search_path = public as $$
begin
  update public.inbox_agent_executions e set state = 'running', runtime_task_id = p_runtime_task_id,
    heartbeat_at = now(), lease_expires_at = now() + make_interval(secs => p_lease_seconds),
    dispatch_expires_at = null
  from public.email_scan_runs r
  where e.id = p_execution_id and e.dispatch_token = p_dispatch_token and e.state = 'leased'
    and e.dispatch_expires_at > now() and r.id = e.scan_run_id and r.cancel_requested_at is null;
  if found then return true; end if;
  update public.inbox_agent_executions e set state = 'cancelled', completed_at = now(), lease_expires_at = null
  where e.id = p_execution_id and e.state = 'leased' and e.dispatch_token = p_dispatch_token
    and exists (select 1 from public.email_scan_runs r where r.id = e.scan_run_id and r.cancel_requested_at is not null);
  return false;
end $$;

create or replace function public.release_inbox_agent_dispatch(
  p_execution_id uuid, p_dispatch_token uuid, p_error text default null
) returns boolean language sql security definer set search_path = public as $$
  update public.inbox_agent_executions set state = 'retryable', available_at = now(),
    dispatch_expires_at = null, lease_expires_at = null, last_error = left(p_error, 500)
  where id = p_execution_id and state = 'leased' and dispatch_token = p_dispatch_token returning true;
$$;

create or replace function public.recover_expired_inbox_agent_executions()
returns integer language plpgsql security definer set search_path = public as $$
declare v_execution public.inbox_agent_executions%rowtype; v_count integer := 0;
begin
  for v_execution in select * from public.inbox_agent_executions
    where (state = 'leased' and dispatch_expires_at <= now()) or (state = 'running' and lease_expires_at <= now())
    for update skip locked loop
    v_count := v_count + 1;
    if v_execution.attempt_count >= 3 or v_execution.dispatch_attempt >= 3 then
      update public.inbox_agent_executions set state = 'failed', completed_at = now(),
        lease_expires_at = null, dispatch_expires_at = null,
        last_error = coalesce(last_error, 'Managed page execution could not be recovered.') where id = v_execution.id;
      update public.scan_jobs set status = 'failed', finished_at = now(),
        error = coalesce(error, 'Managed page execution could not be recovered.')
        where id = v_execution.scan_job_id and status in ('pending', 'running');
      perform public.finalize_email_scan_run_if_drained(v_execution.scan_run_id);
    else
      update public.inbox_agent_executions set state = 'retryable', available_at = now(),
        lease_expires_at = null, dispatch_expires_at = null,
        last_error = coalesce(last_error, 'Managed agent execution lease expired.') where id = v_execution.id;
      update public.scan_jobs set status = 'pending', started_at = null
        where id = v_execution.scan_job_id and status = 'running';
    end if;
  end loop;
  return v_count;
end $$;

revoke all on function public.reserve_inbox_agent_executions(integer, integer, integer, integer, integer, integer) from public;
revoke all on function public.attach_inbox_agent_runtime(uuid, uuid, text) from public;
revoke all on function public.claim_dispatched_inbox_agent_execution(uuid, uuid, text, integer) from public;
revoke all on function public.release_inbox_agent_dispatch(uuid, uuid, text) from public;
grant execute on function public.reserve_inbox_agent_executions(integer, integer, integer, integer, integer, integer) to service_role;
grant execute on function public.attach_inbox_agent_runtime(uuid, uuid, text) to service_role;
grant execute on function public.claim_dispatched_inbox_agent_execution(uuid, uuid, text, integer) to service_role;
grant execute on function public.release_inbox_agent_dispatch(uuid, uuid, text) to service_role;
