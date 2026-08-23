-- Per-user, per-merchant priors learned from confirmed and corrected discovery
-- outcomes. Written by the email-scan Edge Function (service_role); authenticated
-- clients may read only their own rows. Deletion cascades with the auth user, so no
-- change to the delete-account function is required.
create table public.merchant_review_priors (
  user_id uuid not null references auth.users(id) on delete cascade,
  canonical_merchant_key text not null check (canonical_merchant_key ~ '^[a-z0-9][a-z0-9-]{0,79}$'),
  field text not null check (field in ('billing_cycle', 'category')),
  value text not null,
  evidence_strength integer not null default 1 check (evidence_strength >= 1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, canonical_merchant_key, field),
  constraint merchant_review_priors_value_valid check (
    (field = 'billing_cycle' and value in ('weekly', 'monthly', 'quarterly', 'yearly')) or
    (field = 'category' and value in ('entertainment', 'work', 'cloud', 'health', 'learning', 'other'))
  )
);
create trigger merchant_review_priors_set_updated_at before update on public.merchant_review_priors for each row execute function public.set_updated_at();

alter table public.merchant_review_priors enable row level security;
create policy "merchant_review_priors_select_own" on public.merchant_review_priors for select to authenticated using ((select auth.uid()) = user_id);
grant select on public.merchant_review_priors to authenticated;
grant all privileges on table public.merchant_review_priors to service_role;
