alter table public.subscriptions
  add column brand_id text;

comment on column public.subscriptions.brand_id is
  'Optional stable identifier for a reviewed bundled subscription-brand logo.';
