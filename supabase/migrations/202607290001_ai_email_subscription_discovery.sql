alter table public.subscriptions
  add column canonical_merchant_key text
  check (
    canonical_merchant_key is null
    or canonical_merchant_key ~ '^[a-z0-9][a-z0-9-]{0,79}$'
  );

create index subscriptions_user_canonical_merchant_idx
  on public.subscriptions (user_id, canonical_merchant_key)
  where canonical_merchant_key is not null;

alter table public.email_connections
  add column last_error text;

alter table public.email_scan_runs
  add column batch_id uuid not null default gen_random_uuid(),
  add column stage text not null default 'queued'
    check (stage in ('queued', 'fetching', 'filtering', 'extracting', 'review_ready', 'completed', 'failed')),
  add column candidate_messages integer not null default 0 check (candidate_messages >= 0),
  add column validation_failures integer not null default 0 check (validation_failures >= 0),
  add column updated_at timestamptz not null default now();

create index email_scan_runs_user_batch_idx
  on public.email_scan_runs (user_id, batch_id, started_at desc);

create trigger email_scan_runs_set_updated_at before update on public.email_scan_runs
for each row execute function public.set_updated_at();

alter table public.detected_billing_events
  add column canonical_merchant_key text
    check (
      canonical_merchant_key is null
      or canonical_merchant_key ~ '^[a-z0-9][a-z0-9-]{0,79}$'
    ),
  add column validation_state text not null default 'valid'
    check (validation_state in ('valid', 'rejected')),
  add column validation_issues text[] not null default '{}',
  add column schema_version text not null default 'billing-event-v1',
  add column model_identifier text,
  add column applied_subscription_id uuid references public.subscriptions(id) on delete set null;

create table public.mail_sync_states (
  connection_id uuid primary key references public.email_connections(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  cursor_kind text not null check (cursor_kind in ('gmail_history', 'microsoft_delta')),
  cursor_value text not null,
  last_successful_at timestamptz not null default now(),
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index mail_sync_states_user_idx on public.mail_sync_states (user_id);

create trigger mail_sync_states_set_updated_at before update on public.mail_sync_states
for each row execute function public.set_updated_at();

create table public.email_scan_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  batch_id uuid not null,
  scan_run_id uuid not null references public.email_scan_runs(id) on delete cascade,
  connection_id uuid not null references public.email_connections(id) on delete cascade,
  status text not null default 'queued'
    check (status in ('queued', 'running', 'completed', 'failed')),
  attempts integer not null default 0 check (attempts between 0 and 5),
  available_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (scan_run_id)
);

create index email_scan_jobs_claim_idx
  on public.email_scan_jobs (user_id, status, available_at, created_at);
create index email_scan_jobs_batch_idx
  on public.email_scan_jobs (user_id, batch_id);

create trigger email_scan_jobs_set_updated_at before update on public.email_scan_jobs
for each row execute function public.set_updated_at();

create table public.subscription_candidates (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  scan_run_id uuid not null references public.email_scan_runs(id) on delete cascade,
  detected_event_id uuid not null references public.detected_billing_events(id) on delete cascade,
  matched_subscription_id uuid references public.subscriptions(id) on delete set null,
  applied_subscription_id uuid references public.subscriptions(id) on delete set null,
  suggested_action text not null
    check (suggested_action in ('add', 'update', 'cancel', 'review')),
  review_status text not null default 'pending'
    check (review_status in ('pending', 'confirmed', 'ignored')),
  merchant_name text not null check (char_length(merchant_name) between 1 and 120),
  canonical_merchant_key text not null
    check (canonical_merchant_key ~ '^[a-z0-9][a-z0-9-]{0,79}$'),
  amount numeric(12, 2),
  currency char(3),
  billing_cycle public.billing_cycle,
  renewal_date date,
  category public.subscription_category not null default 'other',
  event_type public.billing_event_type not null,
  confidence numeric(4, 3) not null check (confidence between 0 and 1),
  evidence text not null default '' check (char_length(evidence) <= 280),
  validation_issues text[] not null default '{}',
  correction_payload jsonb,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (detected_event_id)
);

create index subscription_candidates_user_review_idx
  on public.subscription_candidates (user_id, review_status, created_at desc);
create index subscription_candidates_user_merchant_idx
  on public.subscription_candidates (user_id, canonical_merchant_key);

create trigger subscription_candidates_set_updated_at before update on public.subscription_candidates
for each row execute function public.set_updated_at();

alter table public.mail_sync_states enable row level security;
alter table public.email_scan_jobs enable row level security;
alter table public.subscription_candidates enable row level security;

create policy "mail_sync_states_select_own"
  on public.mail_sync_states for select to authenticated
  using ((select auth.uid()) = user_id);

create policy "email_scan_jobs_select_own"
  on public.email_scan_jobs for select to authenticated
  using ((select auth.uid()) = user_id);

create policy "subscription_candidates_select_own"
  on public.subscription_candidates for select to authenticated
  using ((select auth.uid()) = user_id);

grant select on public.subscription_candidates to authenticated;
grant all privileges on table public.mail_sync_states to service_role;
grant all privileges on table public.email_scan_jobs to service_role;
grant all privileges on table public.subscription_candidates to service_role;
