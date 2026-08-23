-- Bounded, review-first questions for subscription evidence that is useful but
-- not yet deterministic enough to become a subscription candidate.
create table if not exists public.inbox_clarification_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  evidence_bundle_id uuid references public.merchant_evidence_bundles(id) on delete set null,
  detected_event_id uuid references public.detected_billing_events(id) on delete set null,
  canonical_merchant_key text not null check (char_length(canonical_merchant_key) between 1 and 80),
  kind text not null check (kind in ('lifecycle_check', 'identity_check', 'billing_cycle_check')),
  status text not null default 'open' check (status in ('open', 'answered', 'dismissed', 'superseded', 'expired')),
  merchant_name text not null check (char_length(merchant_name) between 1 and 120),
  question text not null check (char_length(question) between 1 and 280),
  explanation text not null check (char_length(explanation) between 1 and 420),
  choices jsonb not null default '[]'::jsonb check (jsonb_typeof(choices) = 'array' and jsonb_array_length(choices) between 2 and 5),
  context jsonb not null default '{}'::jsonb check (jsonb_typeof(context) = 'object'),
  priority integer not null default 0 check (priority between 0 and 100),
  source_received_at timestamptz not null,
  expires_at timestamptz not null,
  resolved_at timestamptz,
  superseded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (expires_at > created_at)
);

create unique index if not exists inbox_clarification_one_open_per_kind
  on public.inbox_clarification_requests (user_id, canonical_merchant_key, kind)
  where status = 'open';

create index if not exists inbox_clarification_open_priority_idx
  on public.inbox_clarification_requests (user_id, priority desc, source_received_at desc)
  where status = 'open';

create index if not exists inbox_clarification_evidence_idx
  on public.inbox_clarification_requests (user_id, evidence_bundle_id, detected_event_id);

create table if not exists public.inbox_clarification_outcomes (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique references public.inbox_clarification_requests(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  answer text not null check (char_length(answer) between 1 and 100),
  effect text not null check (effect in ('retained_uncertain', 'dismissed', 'alias_recorded', 'candidate_created', 'candidate_unblocked')),
  created_at timestamptz not null default now()
);

create index if not exists inbox_clarification_outcomes_user_idx
  on public.inbox_clarification_outcomes (user_id, created_at desc);

create or replace function public.resolve_inbox_clarification_request(
  p_request_id uuid,
  p_user_id uuid,
  p_answer text,
  p_effect text
)
returns table (request_id uuid, request_status text, idempotent boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  stored_status text;
begin
  select status into stored_status
  from public.inbox_clarification_requests
  where id = p_request_id and user_id = p_user_id
  for update;

  if stored_status is null then
    raise exception 'Clarification request not found';
  end if;

  if stored_status <> 'open' then
    return query select p_request_id, stored_status, true;
    return;
  end if;

  update public.inbox_clarification_requests
  set status = case when p_answer = 'not_sure' then 'dismissed' else 'answered' end,
      resolved_at = now()
  where id = p_request_id and user_id = p_user_id and status = 'open';

  insert into public.inbox_clarification_outcomes (request_id, user_id, answer, effect)
  values (p_request_id, p_user_id, p_answer, p_effect);

  return query select p_request_id,
    case when p_answer = 'not_sure' then 'dismissed' else 'answered' end,
    false;
end;
$$;

revoke all on function public.resolve_inbox_clarification_request(uuid, uuid, text, text) from public;
grant execute on function public.resolve_inbox_clarification_request(uuid, uuid, text, text) to service_role;

alter table public.inbox_clarification_requests enable row level security;
alter table public.inbox_clarification_outcomes enable row level security;

drop policy if exists "Users read own inbox clarification requests" on public.inbox_clarification_requests;
create policy "Users read own inbox clarification requests"
  on public.inbox_clarification_requests for select
  using (auth.uid() = user_id);

drop policy if exists "Users read own inbox clarification outcomes" on public.inbox_clarification_outcomes;
create policy "Users read own inbox clarification outcomes"
  on public.inbox_clarification_outcomes for select
  using (auth.uid() = user_id);

revoke all on public.inbox_clarification_requests from anon, authenticated;
revoke all on public.inbox_clarification_outcomes from anon, authenticated;
grant select on public.inbox_clarification_requests to authenticated;
grant select on public.inbox_clarification_outcomes to authenticated;

drop trigger if exists set_inbox_clarification_requests_updated_at on public.inbox_clarification_requests;
create trigger set_inbox_clarification_requests_updated_at
  before update on public.inbox_clarification_requests
  for each row execute function public.set_updated_at();
