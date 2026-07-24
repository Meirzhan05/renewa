create extension if not exists pgcrypto;

create type public.billing_cycle as enum ('weekly', 'monthly', 'quarterly', 'yearly');
create type public.subscription_category as enum ('entertainment', 'work', 'cloud', 'health', 'learning', 'other');
create type public.subscription_status as enum ('active', 'canceled', 'paused');
create type public.mail_provider as enum ('google', 'microsoft');
create type public.scan_status as enum ('running', 'completed', 'failed');
create type public.billing_event_type as enum ('created', 'renewed', 'price_changed', 'canceled', 'trial_started', 'trial_ending');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  default_currency char(3) not null default 'USD',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade default auth.uid(),
  name text not null check (char_length(name) between 1 and 120),
  price numeric(12, 2) not null check (price >= 0),
  currency char(3) not null default 'USD',
  billing_cycle public.billing_cycle not null default 'monthly',
  next_renewal_date date not null,
  category public.subscription_category not null default 'other',
  status public.subscription_status not null default 'active',
  icon_name text not null default 'S',
  tint_hex text not null default '#5A967D' check (tint_hex ~ '^#[0-9A-Fa-f]{6}$'),
  source text not null default 'manual' check (source in ('manual', 'email')),
  source_key text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index subscriptions_source_key_unique
  on public.subscriptions(user_id, source_key);
create index subscriptions_user_renewal_idx
  on public.subscriptions(user_id, next_renewal_date)
  where status = 'active';

-- OAuth secrets remain in these tables behind RLS with no client policies.
-- Only service-role Edge Functions can read or write them.
create table public.email_connections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  provider public.mail_provider not null,
  email text,
  encrypted_tokens text not null,
  token_expires_at timestamptz,
  scopes text[] not null default '{}',
  last_scanned_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(user_id, provider)
);

create table public.oauth_states (
  state_hash text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  provider public.mail_provider not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create table public.email_scan_runs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  provider public.mail_provider not null,
  status public.scan_status not null default 'running',
  messages_scanned integer not null default 0,
  events_detected integer not null default 0,
  subscriptions_added integer not null default 0,
  subscriptions_canceled integer not null default 0,
  error_message text,
  started_at timestamptz not null default now(),
  completed_at timestamptz
);

create table public.detected_billing_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  scan_run_id uuid not null references public.email_scan_runs(id) on delete cascade,
  provider public.mail_provider not null,
  provider_message_id text not null,
  event_type public.billing_event_type not null,
  merchant_name text not null,
  amount numeric(12, 2),
  currency char(3),
  billing_cycle public.billing_cycle,
  event_date date,
  renewal_date date,
  confidence numeric(4, 3) not null check (confidence between 0 and 1),
  evidence text,
  applied boolean not null default false,
  created_at timestamptz not null default now(),
  unique(user_id, provider, provider_message_id, event_type)
);

alter table public.profiles enable row level security;
alter table public.subscriptions enable row level security;
alter table public.email_connections enable row level security;
alter table public.oauth_states enable row level security;
alter table public.email_scan_runs enable row level security;
alter table public.detected_billing_events enable row level security;

create policy "profiles_select_own"
  on public.profiles for select to authenticated
  using ((select auth.uid()) = id);
create policy "profiles_update_own"
  on public.profiles for update to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

create policy "subscriptions_select_own"
  on public.subscriptions for select to authenticated
  using ((select auth.uid()) = user_id);
create policy "subscriptions_insert_own"
  on public.subscriptions for insert to authenticated
  with check ((select auth.uid()) = user_id);
create policy "subscriptions_update_own"
  on public.subscriptions for update to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);
create policy "subscriptions_delete_own"
  on public.subscriptions for delete to authenticated
  using ((select auth.uid()) = user_id);

create policy "scan_runs_select_own"
  on public.email_scan_runs for select to authenticated
  using ((select auth.uid()) = user_id);
create policy "detected_events_select_own"
  on public.detected_billing_events for select to authenticated
  using ((select auth.uid()) = user_id);

revoke all on public.email_connections from anon, authenticated;
revoke all on public.oauth_states from anon, authenticated;
grant select, insert, update, delete on public.subscriptions to authenticated;
grant select, update on public.profiles to authenticated;
grant select on public.email_scan_runs, public.detected_billing_events to authenticated;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_set_updated_at before update on public.profiles
for each row execute function public.set_updated_at();
create trigger subscriptions_set_updated_at before update on public.subscriptions
for each row execute function public.set_updated_at();
create trigger email_connections_set_updated_at before update on public.email_connections
for each row execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name', split_part(new.email, '@', 1)));
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
