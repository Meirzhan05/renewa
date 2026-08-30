-- Durable product-side ledger for managed Inbox agent tasks. Trigger.dev owns scheduling and
-- execution; this table remains the authoritative, owner-scoped audit and recovery record.
do $$ begin
  create type public.inbox_agent_execution_state as enum (
    'queued', 'leased', 'running', 'retryable', 'completed', 'failed', 'cancelled'
  );
exception when duplicate_object then null;
end $$;

alter type public.scan_status add value if not exists 'cancelled';

alter table public.email_scan_runs
  add column if not exists cancel_requested_at timestamptz,
  add column if not exists cancelled_at timestamptz;

alter table public.email_scan_runs drop constraint if exists email_scan_runs_stage_check;
alter table public.email_scan_runs
  add constraint email_scan_runs_stage_check check (
    stage in (
      'queued', 'fetching', 'filtering', 'extracting', 'reasoning', 'review_ready', 'completed',
      'failed', 'cancelled'
    )
  );

alter table public.scan_jobs
  add column if not exists connection_id uuid references public.email_connections(id) on delete cascade;
create index if not exists scan_jobs_connection_idx on public.scan_jobs (connection_id, status, created_at);

create table if not exists public.inbox_agent_executions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  scan_run_id uuid not null references public.email_scan_runs(id) on delete cascade,
  scan_job_id uuid unique references public.scan_jobs(id) on delete cascade,
  connection_id uuid not null references public.email_connections(id) on delete cascade,
  task_kind text not null check (task_kind in ('scan_run', 'page_analysis')),
  idempotency_key text not null unique check (char_length(idempotency_key) between 1 and 240),
  runtime_task_id text unique,
  state public.inbox_agent_execution_state not null default 'queued',
  attempt_count integer not null default 0 check (attempt_count >= 0 and attempt_count <= 8),
  available_at timestamptz not null default now(),
  leased_at timestamptz,
  lease_expires_at timestamptz,
  heartbeat_at timestamptz,
  completed_at timestamptz,
  last_error text,
  correlation_id uuid not null default gen_random_uuid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists inbox_agent_executions_admission_idx
  on public.inbox_agent_executions (state, available_at, created_at);
create index if not exists inbox_agent_executions_user_idx
  on public.inbox_agent_executions (user_id, state, created_at);
create index if not exists inbox_agent_executions_run_idx
  on public.inbox_agent_executions (scan_run_id, state, created_at);

drop trigger if exists inbox_agent_executions_set_updated_at on public.inbox_agent_executions;
create trigger inbox_agent_executions_set_updated_at before update on public.inbox_agent_executions
for each row execute function public.set_updated_at();

alter table public.inbox_agent_executions enable row level security;
create policy "inbox_agent_executions_select_own"
  on public.inbox_agent_executions for select to authenticated
  using ((select auth.uid()) = user_id);
grant select on public.inbox_agent_executions to authenticated;
grant all privileges on table public.inbox_agent_executions to service_role;

create or replace function public.admit_inbox_agent_execution(
  p_user_id uuid,
  p_scan_run_id uuid,
  p_scan_job_id uuid,
  p_connection_id uuid,
  p_task_kind text,
  p_idempotency_key text,
  p_runtime_task_id text default null
)
returns public.inbox_agent_executions
language plpgsql
security definer
set search_path = public
as $$
declare v_execution public.inbox_agent_executions%rowtype;
begin
  insert into public.inbox_agent_executions (
    user_id, scan_run_id, scan_job_id, connection_id, task_kind, idempotency_key, runtime_task_id
  ) values (
    p_user_id, p_scan_run_id, p_scan_job_id, p_connection_id, p_task_kind, p_idempotency_key,
    p_runtime_task_id
  )
  on conflict (idempotency_key) do update
  set runtime_task_id = coalesce(excluded.runtime_task_id, inbox_agent_executions.runtime_task_id)
  returning * into v_execution;
  return v_execution;
end;
$$;

create or replace function public.claim_inbox_agent_execution(
  p_execution_id uuid,
  p_runtime_task_id text,
  p_lease_seconds integer default 120
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_execution public.inbox_agent_executions%rowtype;
declare v_cancelled boolean;
begin
  if p_lease_seconds < 30 or p_lease_seconds > 900 then
    raise exception 'lease seconds must be between 30 and 900';
  end if;
  select * into v_execution from public.inbox_agent_executions where id = p_execution_id for update;
  if not found or v_execution.state not in ('queued', 'retryable') or v_execution.available_at > now() then
    return false;
  end if;
  select cancel_requested_at is not null into v_cancelled from public.email_scan_runs
  where id = v_execution.scan_run_id for update;
  if coalesce(v_cancelled, true) then
    update public.inbox_agent_executions
    set state = 'cancelled', completed_at = now(), lease_expires_at = null
    where id = p_execution_id;
    return false;
  end if;
  update public.inbox_agent_executions
  set state = 'running', runtime_task_id = coalesce(p_runtime_task_id, runtime_task_id),
      attempt_count = attempt_count + 1, leased_at = now(), heartbeat_at = now(),
      lease_expires_at = now() + make_interval(secs => p_lease_seconds), last_error = null
  where id = p_execution_id;
  return true;
end;
$$;

create or replace function public.heartbeat_inbox_agent_execution(
  p_execution_id uuid,
  p_lease_seconds integer default 120
)
returns boolean
language sql
security definer
set search_path = public
as $$
  update public.inbox_agent_executions
  set heartbeat_at = now(), lease_expires_at = now() + make_interval(secs => p_lease_seconds)
  where id = p_execution_id and state = 'running' and lease_expires_at > now()
  returning true;
$$;

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
begin
  if p_state not in ('completed', 'failed', 'cancelled', 'retryable') then
    raise exception 'invalid terminal execution state';
  end if;
  update public.inbox_agent_executions
  set state = p_state, last_error = left(p_error, 500), lease_expires_at = null,
      completed_at = case when p_state in ('completed', 'failed', 'cancelled') then now() else null end,
      available_at = case when p_state = 'retryable'
        then now() + make_interval(secs => least(300, greatest(3, attempt_count * attempt_count * 3)))
        else available_at end
  where id = p_execution_id and state not in ('completed', 'failed', 'cancelled');
  return found;
end;
$$;

create or replace function public.recover_expired_inbox_agent_executions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_count integer;
begin
  with recovered as (
    update public.inbox_agent_executions
    set state = case when attempt_count >= 3 then 'failed'::public.inbox_agent_execution_state
      else 'retryable'::public.inbox_agent_execution_state end,
        available_at = now(), lease_expires_at = null,
        completed_at = case when attempt_count >= 3 then now() else null end,
        last_error = coalesce(last_error, 'Agent execution lease expired.')
    where state = 'running' and lease_expires_at <= now()
    returning id
  ) select count(*) into v_count from recovered;
  return v_count;
end;
$$;

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
  set state = 'cancelled', completed_at = now(), lease_expires_at = null
  where scan_run_id = p_run_id and state in ('queued', 'leased', 'retryable');
  return true;
end;
$$;

revoke all on function public.admit_inbox_agent_execution(uuid, uuid, uuid, uuid, text, text, text) from public;
revoke all on function public.claim_inbox_agent_execution(uuid, text, integer) from public;
revoke all on function public.heartbeat_inbox_agent_execution(uuid, integer) from public;
revoke all on function public.complete_inbox_agent_execution(uuid, public.inbox_agent_execution_state, text) from public;
revoke all on function public.recover_expired_inbox_agent_executions() from public;
revoke all on function public.cancel_email_scan_run(uuid, uuid) from public;
grant execute on function public.admit_inbox_agent_execution(uuid, uuid, uuid, uuid, text, text, text) to service_role;
grant execute on function public.claim_inbox_agent_execution(uuid, text, integer) to service_role;
grant execute on function public.heartbeat_inbox_agent_execution(uuid, integer) to service_role;
grant execute on function public.complete_inbox_agent_execution(uuid, public.inbox_agent_execution_state, text) to service_role;
grant execute on function public.recover_expired_inbox_agent_executions() to service_role;
grant execute on function public.cancel_email_scan_run(uuid, uuid) to service_role;

-- Preserve the paginated completion invariant while making a persisted cancellation authoritative
-- once no in-flight page can write another result.
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

  if v_run.cancel_requested_at is not null then
    update public.email_scan_runs
    set status = 'cancelled', stage = 'cancelled', cancelled_at = coalesce(cancelled_at, now()),
        completed_at = coalesce(completed_at, now()), error_message = null
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
        completed_at = coalesce(completed_at, now())
    where id = p_run_id;
    return true;
  end if;

  select exists (
    select 1 from public.subscription_candidates
    where scan_run_id = p_run_id and review_status = 'pending'
  ) into v_has_candidates;
  update public.email_scan_runs
  set status = 'completed', stage = case when v_has_candidates then 'review_ready' else 'completed' end,
      completed_at = coalesce(completed_at, now())
  where id = p_run_id;
  return true;
end;
$$;
