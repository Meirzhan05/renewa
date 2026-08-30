-- The persistent worker queue used to be installed manually from worker/migrations. Keep this
-- migration idempotent so `supabase db reset` creates the same schema used by the Edge Function.
create extension if not exists "pgcrypto";

create table if not exists public.scan_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  provider text not null,
  access_token text,
  raw_messages jsonb not null default '[]'::jsonb,
  status text not null default 'pending'
    check (status in ('pending', 'running', 'completed', 'failed')),
  error text,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  scan_run_id uuid,
  batch_id uuid
);

alter table public.scan_jobs
  add column if not exists access_token text,
  add column if not exists raw_messages jsonb not null default '[]'::jsonb,
  add column if not exists scan_run_id uuid,
  add column if not exists batch_id uuid;

create index if not exists scan_jobs_queue_idx on public.scan_jobs (status, created_at);
create index if not exists scan_jobs_run_idx on public.scan_jobs (scan_run_id, status, created_at);

create table if not exists public.scan_outcomes (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.scan_jobs (id) on delete cascade,
  kind text not null check (kind in ('present', 'near_miss')),
  merchant_key text not null,
  merchant_name text not null default '',
  assessment jsonb not null,
  created_at timestamptz not null default now()
);

create index if not exists scan_outcomes_job_idx on public.scan_outcomes (job_id);

-- A run is shared by every historical mailbox page. Serialize finalization on that run and only
-- complete it once neither queue still contains work. Both the Edge Function and worker call this
-- after their own terminal transition, which makes the hand-off race harmless.
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
  select * into v_run
  from public.email_scan_runs
  where id = p_run_id
  for update;

  if not found then return false; end if;

  select exists (
    select 1 from public.email_scan_jobs
    where scan_run_id = p_run_id and status in ('queued', 'running')
  ) or exists (
    select 1 from public.scan_jobs
    where scan_run_id = p_run_id and status in ('pending', 'running')
  ) into v_active;
  if v_active then return false; end if;

  select exists (
    select 1 from public.email_scan_jobs
    where scan_run_id = p_run_id and status = 'failed'
  ) or exists (
    select 1 from public.scan_jobs
    where scan_run_id = p_run_id and status = 'failed'
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
  set status = 'completed',
      stage = case when v_has_candidates then 'review_ready' else 'completed' end,
      completed_at = coalesce(completed_at, now())
  where id = p_run_id;
  return true;
end;
$$;

revoke all on function public.finalize_email_scan_run_if_drained(uuid) from public;
grant execute on function public.finalize_email_scan_run_if_drained(uuid) to service_role;
