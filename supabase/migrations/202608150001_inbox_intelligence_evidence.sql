alter table public.email_scan_runs
  add column withheld_ambiguities integer not null default 0 check (withheld_ambiguities >= 0),
  add column telemetry jsonb not null default '{}'::jsonb;

create table public.merchant_evidence_bundles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  canonical_merchant_key text not null check (canonical_merchant_key ~ '^[a-z0-9][a-z0-9-]{0,79}$'),
  lifecycle_state text not null check (lifecycle_state in ('current', 'ended', 'uncertain')),
  resolution_reason text not null check (char_length(resolution_reason) between 1 and 120),
  supporting_event_id uuid references public.detected_billing_events(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, canonical_merchant_key)
);
create index merchant_evidence_bundles_user_updated_idx on public.merchant_evidence_bundles (user_id, updated_at desc);
create trigger merchant_evidence_bundles_set_updated_at before update on public.merchant_evidence_bundles for each row execute function public.set_updated_at();

create table public.merchant_evidence_bundle_events (
  bundle_id uuid not null references public.merchant_evidence_bundles(id) on delete cascade,
  event_id uuid not null references public.detected_billing_events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (bundle_id, event_id)
);
create index merchant_evidence_bundle_events_user_event_idx on public.merchant_evidence_bundle_events (user_id, event_id);

create table public.reviewed_merchant_aliases (
  user_id uuid not null references auth.users(id) on delete cascade,
  alias_key text not null check (alias_key ~ '^[a-z0-9][a-z0-9-]{0,79}$'),
  canonical_merchant_key text not null check (canonical_merchant_key ~ '^[a-z0-9][a-z0-9-]{0,79}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, alias_key)
);
create trigger reviewed_merchant_aliases_set_updated_at before update on public.reviewed_merchant_aliases for each row execute function public.set_updated_at();

create table public.merchant_identity_adjudications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  event_id uuid not null references public.detected_billing_events(id) on delete cascade,
  decision text not null check (decision in ('same_merchant', 'different_merchant', 'abstain', 'invalid')),
  explanation text not null default '' check (char_length(explanation) <= 280),
  model_identifier text,
  schema_version text not null default 'merchant-adjudication-v1',
  created_at timestamptz not null default now(),
  unique (event_id)
);

create table public.subscription_candidate_review_outcomes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  candidate_id uuid not null references public.subscription_candidates(id) on delete cascade,
  outcome text not null check (outcome in ('confirmed', 'corrected', 'ignored', 'suppressed', 'canceled')),
  correction_reason text check (correction_reason in ('wrong_merchant', 'wrong_amount', 'wrong_cycle', 'not_a_subscription', 'other')),
  proposed_fields jsonb not null default '{}'::jsonb,
  applied_fields jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index subscription_candidate_review_outcomes_user_created_idx on public.subscription_candidate_review_outcomes (user_id, created_at desc);

alter table public.subscription_candidates
  add column evidence_bundle_id uuid references public.merchant_evidence_bundles(id) on delete set null,
  add column resolution_reason text,
  add column correction_reason text check (correction_reason in ('wrong_merchant', 'wrong_amount', 'wrong_cycle', 'not_a_subscription', 'other'));

alter table public.merchant_evidence_bundles enable row level security;
alter table public.merchant_evidence_bundle_events enable row level security;
alter table public.reviewed_merchant_aliases enable row level security;
alter table public.merchant_identity_adjudications enable row level security;
alter table public.subscription_candidate_review_outcomes enable row level security;

create policy "merchant_evidence_bundles_select_own" on public.merchant_evidence_bundles for select to authenticated using ((select auth.uid()) = user_id);
create policy "merchant_evidence_bundle_events_select_own" on public.merchant_evidence_bundle_events for select to authenticated using ((select auth.uid()) = user_id);
create policy "reviewed_merchant_aliases_select_own" on public.reviewed_merchant_aliases for select to authenticated using ((select auth.uid()) = user_id);
create policy "merchant_identity_adjudications_select_own" on public.merchant_identity_adjudications for select to authenticated using ((select auth.uid()) = user_id);
create policy "subscription_candidate_review_outcomes_select_own" on public.subscription_candidate_review_outcomes for select to authenticated using ((select auth.uid()) = user_id);

grant select on public.merchant_evidence_bundles, public.merchant_evidence_bundle_events, public.reviewed_merchant_aliases, public.merchant_identity_adjudications, public.subscription_candidate_review_outcomes to authenticated;
grant all privileges on table public.merchant_evidence_bundles, public.merchant_evidence_bundle_events, public.reviewed_merchant_aliases, public.merchant_identity_adjudications, public.subscription_candidate_review_outcomes to service_role;
