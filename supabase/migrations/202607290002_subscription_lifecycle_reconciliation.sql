alter table public.detected_billing_events
  add column source_received_at timestamptz;

update public.detected_billing_events
set source_received_at = coalesce(event_date::timestamptz, created_at)
where source_received_at is null;

alter table public.detected_billing_events
  alter column source_received_at set not null;

create index detected_billing_events_user_merchant_received_idx
  on public.detected_billing_events (
    user_id,
    canonical_merchant_key,
    source_received_at asc
  )
  where canonical_merchant_key is not null;

alter table public.subscription_candidates
  add column system_resolution_reason text
    check (
      system_resolution_reason is null
      or char_length(system_resolution_reason) between 1 and 120
    ),
  add column system_resolved_at timestamptz;

create table public.merchant_discovery_suppressions (
  user_id uuid not null references auth.users(id) on delete cascade,
  canonical_merchant_key text not null
    check (canonical_merchant_key ~ '^[a-z0-9][a-z0-9-]{0,79}$'),
  reason text not null default 'unused'
    check (reason in ('unused')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, canonical_merchant_key)
);

create trigger merchant_discovery_suppressions_set_updated_at
before update on public.merchant_discovery_suppressions
for each row execute function public.set_updated_at();

alter table public.merchant_discovery_suppressions enable row level security;

create policy "merchant_discovery_suppressions_select_own"
  on public.merchant_discovery_suppressions for select to authenticated
  using ((select auth.uid()) = user_id);

grant select on public.merchant_discovery_suppressions to authenticated;
grant all privileges on table public.merchant_discovery_suppressions to service_role;
