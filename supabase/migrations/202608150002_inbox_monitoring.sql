alter table public.email_connections
  add column automatic_monitoring_enabled boolean not null default false,
  add column last_automatic_scan_at timestamptz;

create index email_connections_monitoring_due_idx
  on public.email_connections (automatic_monitoring_enabled, last_automatic_scan_at)
  where automatic_monitoring_enabled;
