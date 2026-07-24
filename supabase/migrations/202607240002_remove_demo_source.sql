alter table public.subscriptions
  drop constraint subscriptions_source_check;

alter table public.subscriptions
  add constraint subscriptions_source_check
  check (source in ('manual', 'email'));
