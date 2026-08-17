create table public.notification_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  inbox_scan_outcomes_enabled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger notification_preferences_set_updated_at before update on public.notification_preferences
for each row execute function public.set_updated_at();

create table public.notification_device_installations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  platform text not null default 'ios' check (platform = 'ios'),
  environment text not null check (environment in ('sandbox', 'production')),
  device_token text not null unique check (char_length(device_token) between 32 and 512),
  authorization_status text not null default 'unknown'
    check (authorization_status in ('unknown', 'denied', 'authorized', 'provisional')),
  is_enabled boolean not null default true,
  last_seen_at timestamptz not null default now(),
  disabled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index notification_device_installations_user_enabled_idx
  on public.notification_device_installations (user_id, is_enabled, updated_at desc);
create trigger notification_device_installations_set_updated_at before update on public.notification_device_installations
for each row execute function public.set_updated_at();

create table public.inbox_scan_live_activities (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  batch_id uuid not null,
  installation_id uuid not null references public.notification_device_installations(id) on delete cascade,
  activity_id text not null check (char_length(activity_id) between 1 and 255),
  push_token text not null check (char_length(push_token) between 32 and 1024),
  last_stage text not null default 'queued',
  last_scanned integer not null default 0 check (last_scanned >= 0),
  stale_at timestamptz,
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (batch_id, installation_id)
);
create index inbox_scan_live_activities_batch_active_idx
  on public.inbox_scan_live_activities (batch_id, ended_at)
  where ended_at is null;
create trigger inbox_scan_live_activities_set_updated_at before update on public.inbox_scan_live_activities
for each row execute function public.set_updated_at();

create table public.notification_outbox (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  batch_id uuid not null,
  event_type text not null check (event_type in ('inbox_scan_outcome', 'inbox_scan_live_update')),
  outcome text check (outcome in ('review_ready', 'no_new_discoveries', 'reconnect_required')),
  aggregate_count integer not null default 0 check (aggregate_count >= 0),
  stage text,
  scanned integer not null default 0 check (scanned >= 0),
  connection_count integer not null default 0 check (connection_count >= 0),
  route text not null default 'inbox-intelligence',
  deduplication_key text not null unique check (char_length(deduplication_key) between 1 and 200),
  status text not null default 'queued' check (status in ('queued', 'sending', 'sent', 'failed', 'cancelled')),
  available_at timestamptz not null default now(),
  lease_expires_at timestamptz,
  attempts integer not null default 0 check (attempts between 0 and 5),
  sent_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index notification_outbox_claim_idx
  on public.notification_outbox (status, available_at, created_at);
create index notification_outbox_user_batch_idx
  on public.notification_outbox (user_id, batch_id, created_at desc);
create trigger notification_outbox_set_updated_at before update on public.notification_outbox
for each row execute function public.set_updated_at();

create table public.notification_deliveries (
  id uuid primary key default gen_random_uuid(),
  outbox_id uuid not null references public.notification_outbox(id) on delete cascade,
  installation_id uuid references public.notification_device_installations(id) on delete set null,
  live_activity_id uuid references public.inbox_scan_live_activities(id) on delete set null,
  status text not null check (status in ('sent', 'failed', 'invalid_token', 'suppressed')),
  provider_message_id text,
  provider_reason text,
  created_at timestamptz not null default now(),
  unique (outbox_id, installation_id),
  unique (outbox_id, live_activity_id)
);
create index notification_deliveries_outbox_idx on public.notification_deliveries (outbox_id, created_at desc);

alter table public.notification_preferences enable row level security;
alter table public.notification_device_installations enable row level security;
alter table public.inbox_scan_live_activities enable row level security;
alter table public.notification_outbox enable row level security;
alter table public.notification_deliveries enable row level security;

create policy "notification_preferences_select_own" on public.notification_preferences
  for select to authenticated using ((select auth.uid()) = user_id);

grant select on public.notification_preferences to authenticated;
grant all privileges on table public.notification_preferences, public.notification_device_installations,
  public.inbox_scan_live_activities, public.notification_outbox, public.notification_deliveries to service_role;

create or replace function public.publish_inbox_scan_notification_state(
  p_user_id uuid,
  p_batch_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job_count integer;
  v_all_terminal boolean;
  v_run_count integer;
  v_scanned integer;
  v_pending_count integer;
  v_has_authorization_failure boolean;
  v_has_other_failure boolean;
  v_has_active_activity boolean;
  v_outcome text;
  v_stage text;
  v_marker text;
begin
  select count(*), coalesce(bool_and(status in ('completed', 'failed')), false)
  into v_job_count, v_all_terminal
  from public.email_scan_jobs
  where user_id = p_user_id and batch_id = p_batch_id;
  if v_job_count = 0 then return; end if;

  select
    count(*),
    coalesce(sum(messages_scanned), 0),
    coalesce(bool_or(coalesce(error_message, '') ~* 'authorization|access token|reconnect your inbox|token.*expired'), false),
    coalesce(bool_or(
      coalesce(error_message, '') <> ''
      and coalesce(error_message, '') !~* 'authorization|access token|reconnect your inbox|token.*expired'
    ), false)
  into v_run_count, v_scanned, v_has_authorization_failure, v_has_other_failure
  from public.email_scan_runs
  where user_id = p_user_id and batch_id = p_batch_id;

  select exists(
    select 1 from public.inbox_scan_live_activities
    where user_id = p_user_id and batch_id = p_batch_id and ended_at is null
  ) into v_has_active_activity;

  if not v_all_terminal then
    if v_has_active_activity then
      v_marker := 'scanning:' || v_scanned::text;
      insert into public.notification_outbox (
        user_id, batch_id, event_type, aggregate_count, stage, scanned, connection_count, route, deduplication_key
      ) values (
        p_user_id, p_batch_id, 'inbox_scan_live_update', 0, 'scanning', v_scanned, v_run_count,
        'inbox-intelligence', 'inbox-live:' || p_batch_id::text || ':' || v_marker
      ) on conflict (deduplication_key) do nothing;
    end if;
    return;
  end if;

  select count(*) into v_pending_count
  from public.subscription_candidates
  where user_id = p_user_id
    and scan_run_id in (
      select id from public.email_scan_runs where user_id = p_user_id and batch_id = p_batch_id
    )
    and review_status = 'pending';

  v_outcome := case
    when v_pending_count > 0 then 'review_ready'
    when v_has_authorization_failure then 'reconnect_required'
    when v_has_other_failure then null
    else 'no_new_discoveries'
  end;
  if v_outcome is null then return; end if;

  v_stage := case when v_outcome = 'review_ready' then 'review_ready' else 'completed' end;
  insert into public.notification_outbox (
    user_id, batch_id, event_type, outcome, aggregate_count, stage, scanned, connection_count, route, deduplication_key
  ) values (
    p_user_id, p_batch_id, 'inbox_scan_outcome', v_outcome, v_pending_count, v_stage, v_scanned, v_run_count,
    'inbox-intelligence', 'inbox-scan:' || p_batch_id::text || ':' || v_outcome
  ) on conflict (deduplication_key) do nothing;

  if v_has_active_activity then
    insert into public.notification_outbox (
      user_id, batch_id, event_type, outcome, aggregate_count, stage, scanned, connection_count, route, deduplication_key
    ) values (
      p_user_id, p_batch_id, 'inbox_scan_live_update', v_outcome, v_pending_count, v_stage, v_scanned, v_run_count,
      'inbox-intelligence', 'inbox-live:' || p_batch_id::text || ':' || v_outcome
    ) on conflict (deduplication_key) do nothing;
  end if;
end;
$$;

revoke all on function public.publish_inbox_scan_notification_state(uuid, uuid) from public, anon, authenticated;
grant execute on function public.publish_inbox_scan_notification_state(uuid, uuid) to service_role;
