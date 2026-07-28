create table public.monthly_spend_snapshots (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  period_start date not null check (period_start = date_trunc('month', period_start)::date),
  currency char(3) not null,
  monthly_total numeric(12, 2) not null check (monthly_total >= 0),
  category_totals jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, period_start, currency)
);

create index monthly_spend_snapshots_user_period_idx
  on public.monthly_spend_snapshots (user_id, period_start desc);

create table public.insight_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  fact_fingerprint text not null,
  payload jsonb not null,
  model_identifier text,
  generated_at timestamptz not null default now(),
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (user_id, fact_fingerprint)
);

create index insight_reports_user_expires_idx
  on public.insight_reports (user_id, expires_at desc);

alter table public.monthly_spend_snapshots enable row level security;
alter table public.insight_reports enable row level security;

create policy "monthly_spend_snapshots_select_own"
  on public.monthly_spend_snapshots for select to authenticated
  using ((select auth.uid()) = user_id);

create policy "insight_reports_select_own"
  on public.insight_reports for select to authenticated
  using ((select auth.uid()) = user_id);

grant select on public.monthly_spend_snapshots, public.insight_reports to authenticated;

create trigger monthly_spend_snapshots_set_updated_at before update on public.monthly_spend_snapshots
for each row execute function public.set_updated_at();

create or replace function public.capture_monthly_spend_snapshot(
  snapshot_user_id uuid,
  snapshot_period date default date_trunc('month', now())::date
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.monthly_spend_snapshots
  where user_id = snapshot_user_id
    and period_start = snapshot_period
    and not exists (
      select 1 from public.subscriptions
      where user_id = snapshot_user_id and status = 'active'
        and currency = public.monthly_spend_snapshots.currency
    );

  insert into public.monthly_spend_snapshots (
    user_id, period_start, currency, monthly_total, category_totals
  )
  select
    grouped.user_id,
    snapshot_period,
    grouped.currency,
    round(sum(grouped.category_total), 2),
    jsonb_object_agg(grouped.category, grouped.category_total)
  from (
    select
      user_id,
      currency,
      category::text as category,
      round(sum(price * case billing_cycle
        when 'weekly' then 4.345
        when 'monthly' then 1
        when 'quarterly' then 0.3333333333
        when 'yearly' then 0.0833333333
      end), 2) as category_total
    from public.subscriptions
    where user_id = snapshot_user_id and status = 'active'
    group by user_id, currency, category
  ) as grouped
  group by grouped.user_id, grouped.currency
  on conflict (user_id, period_start, currency) do update
  set monthly_total = excluded.monthly_total,
      category_totals = excluded.category_totals,
      updated_at = now();
end;
$$;

create or replace function public.capture_all_monthly_spend_snapshots()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  active_user_id uuid;
begin
  for active_user_id in
    select distinct user_id from public.subscriptions where status = 'active'
  loop
    perform public.capture_monthly_spend_snapshot(active_user_id);
  end loop;
end;
$$;

create or replace function public.capture_snapshot_after_subscription_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.capture_monthly_spend_snapshot(coalesce(new.user_id, old.user_id));
  if tg_op = 'UPDATE' and new.user_id is distinct from old.user_id then
    perform public.capture_monthly_spend_snapshot(old.user_id);
  end if;
  return coalesce(new, old);
end;
$$;

create trigger subscriptions_capture_monthly_snapshot
after insert or update or delete on public.subscriptions
for each row execute function public.capture_snapshot_after_subscription_change();

revoke all on function public.capture_monthly_spend_snapshot(uuid, date) from public;
revoke all on function public.capture_all_monthly_spend_snapshots() from public;
