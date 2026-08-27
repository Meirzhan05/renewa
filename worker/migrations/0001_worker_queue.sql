-- Queue schema for the persistent agent worker. The LangGraph *checkpointer* (PostgresSaver)
-- owns run state and creates its own tables via `checkpointer.setup()`; these tables own the
-- surrounding queue only: pending scans, the clarifications a run paused on, and finished
-- outcomes. Enqueue a scan by inserting a `scan_jobs` row (done by the app / an edge function);
-- answer a clarification by setting its `answer` and status = 'answered'.

create extension if not exists "pgcrypto";

create table if not exists public.scan_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  provider text not null,
  -- Sensitive: a short-lived OAuth access token. In production store encrypted or fetch it
  -- just-in-time; do not persist long-lived credentials here.
  access_token text,
  raw_messages jsonb not null default '[]'::jsonb,
  status text not null default 'pending'
    check (status in ('pending', 'running', 'awaiting_user', 'completed', 'failed')),
  error text,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz
);

create index if not exists scan_jobs_queue_idx on public.scan_jobs (status, created_at);

create table if not exists public.scan_clarifications (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.scan_jobs (id) on delete cascade,
  -- LangGraph interrupt id; identifies which pause the answer resumes.
  interrupt_id text not null,
  payload jsonb not null,
  answer text,
  status text not null default 'open'
    check (status in ('open', 'answered', 'resuming', 'resolved')),
  created_at timestamptz not null default now(),
  answered_at timestamptz,
  resolved_at timestamptz,
  unique (job_id, interrupt_id)
);

create index if not exists scan_clarifications_status_idx on public.scan_clarifications (status);

create table if not exists public.scan_outcomes (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.scan_jobs (id) on delete cascade,
  kind text not null check (kind in ('present', 'clarify', 'near_miss')),
  merchant_key text not null,
  merchant_name text not null default '',
  assessment jsonb not null,
  created_at timestamptz not null default now()
);

create index if not exists scan_outcomes_job_idx on public.scan_outcomes (job_id);
