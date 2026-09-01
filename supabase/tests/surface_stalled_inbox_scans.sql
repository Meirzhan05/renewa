-- Run against development only. Creates short-lived fixtures and rolls everything back. Exercises the
-- recover_stalled_inbox_scan_runs() backstop: a run whose dispatched runtime task never materialized is
-- failed past the grace; a fresh run and a run with a live execution are spared; orphaned worker jobs
-- are finalized.
begin;

do $$
declare
  u uuid := gen_random_uuid();
  conn uuid := gen_random_uuid();
  run_stalled uuid := gen_random_uuid();   -- old, queued page window, nothing downstream -> should fail
  run_fresh uuid := gen_random_uuid();     -- within grace -> should be spared
  run_exec uuid := gen_random_uuid();      -- old but has an execution -> not this backstop's job
  run_orphan uuid := gen_random_uuid();    -- no email_scan_runs row; owns an orphaned scan_job
  run_terminal uuid := gen_random_uuid();  -- already failed, but its page window is still queued
  job_exec uuid := gen_random_uuid();
  orphan_job uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (u, 'authenticated', 'authenticated', 'stalled-' || u || '@test.invalid', 'not-a-login', now(),
          '{"provider":"email","providers":["email"]}', '{}', now(), now());
  insert into public.email_connections (id, user_id, provider, email, encrypted_tokens)
  values (conn, u, 'google', 'stalled@test.invalid', 'fixture');

  insert into public.email_scan_runs (id, user_id, provider, status, stage, batch_id, started_at)
  values (run_stalled,  u, 'google', 'running', 'queued', gen_random_uuid(), now() - interval '20 minutes'),
         (run_fresh,    u, 'google', 'running', 'queued', gen_random_uuid(), now()),
         (run_exec,     u, 'google', 'running', 'queued', gen_random_uuid(), now() - interval '20 minutes'),
         (run_terminal, u, 'google', 'failed',  'failed', gen_random_uuid(), now() - interval '20 minutes');

  -- Each run has a queued page window (the edge job). run_terminal's run is already failed but its
  -- window was left queued -- the reaper must finalize it so the batch is not reused.
  insert into public.email_scan_jobs (id, user_id, batch_id, scan_run_id, connection_id, status)
  values (gen_random_uuid(), u, gen_random_uuid(), run_stalled,  conn, 'queued'),
         (gen_random_uuid(), u, gen_random_uuid(), run_fresh,    conn, 'queued'),
         (gen_random_uuid(), u, gen_random_uuid(), run_exec,     conn, 'queued'),
         (gen_random_uuid(), u, gen_random_uuid(), run_terminal, conn, 'queued');

  -- run_exec has downstream work (a worker job + a durable execution) -> the stalled backstop skips it.
  -- (inbox_agent_executions.scan_job_id references scan_jobs.id, so the job row must exist first.)
  insert into public.scan_jobs (id, user_id, provider, status, scan_run_id, batch_id, connection_id, created_at)
  values (job_exec, u, 'google', 'running', run_exec, gen_random_uuid(), conn, now() - interval '20 minutes'),
         -- An orphaned worker job whose parent run does not exist.
         (orphan_job, u, 'google', 'pending', run_orphan, gen_random_uuid(), conn, now() - interval '1 hour');
  insert into public.inbox_agent_executions (user_id, scan_run_id, scan_job_id, connection_id, task_kind, idempotency_key, created_at)
  values (u, run_exec, job_exec, conn, 'page_analysis', 'stalled-test-exec-' || job_exec, now() - interval '20 minutes');

  perform public.recover_stalled_inbox_scan_runs();

  -- 1) The stalled run is failed, and its page window is failed too.
  if not exists (select 1 from public.email_scan_runs where id = run_stalled and status = 'failed') then
    raise exception 'stalled run was not failed';
  end if;
  if exists (select 1 from public.email_scan_jobs where scan_run_id = run_stalled and status in ('queued', 'running')) then
    raise exception 'stalled run page window was not failed';
  end if;

  -- 2) The fresh run (within grace) is spared.
  if not exists (select 1 from public.email_scan_runs where id = run_fresh and status = 'running') then
    raise exception 'fresh run was failed prematurely';
  end if;

  -- 3) The run with a live execution is spared (the execution reaper owns it, not this backstop).
  if not exists (select 1 from public.email_scan_runs where id = run_exec and status = 'running') then
    raise exception 'run with a live execution was failed by the stalled backstop';
  end if;

  -- 4) The orphaned worker job is finalized.
  if not exists (select 1 from public.scan_jobs where id = orphan_job and status = 'failed') then
    raise exception 'orphaned worker job was not finalized';
  end if;

  -- 5) A page window left queued under an already-terminal run is finalized (no dead-batch reuse).
  if exists (select 1 from public.email_scan_jobs where scan_run_id = run_terminal and status in ('queued', 'running')) then
    raise exception 'page window under a terminal run was not finalized';
  end if;

  -- Idempotent: a second pass changes nothing.
  perform public.recover_stalled_inbox_scan_runs();
  if not exists (select 1 from public.email_scan_runs where id = run_fresh and status = 'running') then
    raise exception 'second reaper pass failed a spared run';
  end if;
end $$;

rollback;
