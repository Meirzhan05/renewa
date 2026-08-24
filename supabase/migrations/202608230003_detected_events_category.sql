-- Add the missing `category` column to detected_billing_events. resolveClarification (the
-- billing_cycle_check answer path) already selects and writes this column, but it was never
-- created — so answering a cycle clarification failed with "column ... category does not
-- exist". Backfills existing rows to 'other' so in-flight clarifications become answerable.
alter table public.detected_billing_events
  add column if not exists category public.subscription_category not null default 'other';
