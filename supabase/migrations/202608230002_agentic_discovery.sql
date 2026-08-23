-- Agentic discovery pipeline: persistence for near-misses / abstain reasons (so "we saw
-- this merchant but could not confirm it" is recoverable instead of thrown away) and per-run
-- agent-budget / routing accounting. Written by the email-scan Edge Function (service_role);
-- authenticated clients may read only their own rows. Deletion cascades with the auth user
-- and the owning scan run, so no change to the delete-account function is required.

create table public.discovery_near_misses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  run_id uuid not null references public.email_scan_runs(id) on delete cascade,
  canonical_merchant_key text not null check (canonical_merchant_key ~ '^[a-z0-9][a-z0-9-]{0,79}$'),
  merchant_name text not null default '',
  existence text not null check (existence in ('high', 'low')),
  completeness text not null check (completeness in ('complete', 'incomplete')),
  missing_fields text[] not null default '{}',
  reason text not null,
  created_at timestamptz not null default now()
);

create index discovery_near_misses_user_idx
  on public.discovery_near_misses (user_id, created_at desc);

alter table public.discovery_near_misses enable row level security;
create policy "discovery_near_misses_select_own" on public.discovery_near_misses for select to authenticated using ((select auth.uid()) = user_id);
grant select on public.discovery_near_misses to authenticated;
grant all privileges on table public.discovery_near_misses to service_role;

-- Per-run accounting for the agentic pipeline. Nullable/defaulted so existing rows and the
-- legacy (flag-off) path are unaffected.
alter table public.email_scan_runs
  add column if not exists agent_merchants integer not null default 0,
  add column if not exists agent_tool_calls integer not null default 0,
  add column if not exists agent_tokens integer not null default 0,
  add column if not exists agent_presented integer not null default 0,
  add column if not exists agent_clarifications integer not null default 0,
  add column if not exists agent_near_misses integer not null default 0,
  add column if not exists agent_abstained integer not null default 0;
