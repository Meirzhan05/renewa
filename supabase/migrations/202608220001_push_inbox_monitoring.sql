create table public.inbox_monitoring_watches (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null unique references public.email_connections(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  provider public.mail_provider not null,
  provider_resource_id text,
  encrypted_client_state text,
  expires_at timestamptz,
  health text not null default 'pending'
    check (health in ('pending', 'active', 'checking', 'degraded', 'reconnect_required', 'disabled')),
  last_error text check (last_error is null or char_length(last_error) <= 280),
  last_event_at timestamptz,
  last_renewal_at timestamptz,
  last_renewal_attempt_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index inbox_monitoring_watches_due_idx
  on public.inbox_monitoring_watches (health, expires_at)
  where health in ('active', 'degraded', 'pending');
create index inbox_monitoring_watches_user_idx
  on public.inbox_monitoring_watches (user_id, updated_at desc);
create trigger inbox_monitoring_watches_set_updated_at before update on public.inbox_monitoring_watches
for each row execute function public.set_updated_at();

create table public.inbox_monitoring_event_receipts (
  id uuid primary key default gen_random_uuid(),
  connection_id uuid not null references public.email_connections(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  provider public.mail_provider not null,
  external_event_id text not null check (char_length(external_event_id) between 1 and 256),
  payload_hash text not null check (char_length(payload_hash) between 1 and 128),
  received_at timestamptz not null default now(),
  unique (provider, external_event_id)
);

create index inbox_monitoring_event_receipts_connection_idx
  on public.inbox_monitoring_event_receipts (connection_id, received_at desc);

create table public.inbox_monitoring_due_work (
  connection_id uuid primary key references public.email_connections(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  due_at timestamptz not null,
  event_pending boolean not null default true,
  claimed_at timestamptz,
  completed_at timestamptz,
  attempts integer not null default 0 check (attempts between 0 and 20),
  last_error text check (last_error is null or char_length(last_error) <= 280),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index inbox_monitoring_due_work_claim_idx
  on public.inbox_monitoring_due_work (due_at, claimed_at)
  where event_pending;
create trigger inbox_monitoring_due_work_set_updated_at before update on public.inbox_monitoring_due_work
for each row execute function public.set_updated_at();

alter table public.inbox_monitoring_watches enable row level security;
alter table public.inbox_monitoring_event_receipts enable row level security;
alter table public.inbox_monitoring_due_work enable row level security;

create policy "inbox_monitoring_watches_select_own" on public.inbox_monitoring_watches
  for select to authenticated using ((select auth.uid()) = user_id);

revoke all on public.inbox_monitoring_watches, public.inbox_monitoring_event_receipts,
  public.inbox_monitoring_due_work from anon, authenticated;
grant all privileges on table public.inbox_monitoring_watches, public.inbox_monitoring_event_receipts,
  public.inbox_monitoring_due_work to service_role;
