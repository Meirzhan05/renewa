-- Run against development only. Assumes migration 202608310003 is applied. Rolls everything back.
-- Exercises the retry cap, finalize-on-failed, and the exhausted-retry backstop.
begin;


do $$
declare
  u uuid := gen_random_uuid();
  conn uuid := gen_random_uuid();
  run_cap uuid := gen_random_uuid();      -- complete('retryable') at dispatch_attempt>=3 -> failed
  run_under uuid := gen_random_uuid();    -- complete('retryable') at dispatch_attempt<3  -> stays retryable
  run_backstop uuid := gen_random_uuid(); -- recover_exhausted fails a spent 'retryable'
  job_cap uuid := gen_random_uuid();
  job_under uuid := gen_random_uuid();
  job_backstop uuid := gen_random_uuid();
  exec_cap uuid := gen_random_uuid();
  exec_under uuid := gen_random_uuid();
  exec_backstop uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (u, 'authenticated', 'authenticated', 'term-' || u || '@test.invalid', 'x', now(),
          '{"provider":"email","providers":["email"]}', '{}', now(), now());
  insert into public.email_connections (id, user_id, provider, email, encrypted_tokens)
  values (conn, u, 'google', 'term@test.invalid', 'fixture');
  insert into public.email_scan_runs (id, user_id, provider, status, stage, batch_id, started_at)
  values (run_cap, u, 'google', 'running', 'reasoning', gen_random_uuid(), now()),
         (run_under, u, 'google', 'running', 'reasoning', gen_random_uuid(), now()),
         (run_backstop, u, 'google', 'running', 'reasoning', gen_random_uuid(), now());
  insert into public.scan_jobs (id, user_id, provider, status, scan_run_id, batch_id, connection_id, created_at)
  values (job_cap, u, 'google', 'running', run_cap, gen_random_uuid(), conn, now()),
         (job_under, u, 'google', 'running', run_under, gen_random_uuid(), conn, now()),
         (job_backstop, u, 'google', 'pending', run_backstop, gen_random_uuid(), conn, now());
  insert into public.inbox_agent_executions
    (id, user_id, scan_run_id, scan_job_id, connection_id, task_kind, idempotency_key, state, dispatch_attempt, created_at)
  values
    (exec_cap, u, run_cap, job_cap, conn, 'page_analysis', 'term-cap-'||exec_cap, 'running', 3, now()),
    (exec_under, u, run_under, job_under, conn, 'page_analysis', 'term-under-'||exec_under, 'running', 1, now()),
    (exec_backstop, u, run_backstop, job_backstop, conn, 'page_analysis', 'term-bk-'||exec_backstop, 'retryable', 3, now());

  -- 1) complete('retryable') at dispatch_attempt>=3 is coerced to failed; page + run finalize.
  perform public.complete_inbox_agent_execution(exec_cap, 'retryable', 'Insufficient Balance');
  if not exists (select 1 from public.inbox_agent_executions where id=exec_cap and state='failed') then
    raise exception 'FAIL: capped retryable was not coerced to failed'; end if;
  if not exists (select 1 from public.scan_jobs where id=job_cap and status='failed') then
    raise exception 'FAIL: capped page was not failed'; end if;
  if not exists (select 1 from public.email_scan_runs where id=run_cap and status='failed') then
    raise exception 'FAIL: capped run was not finalized failed'; end if;

  -- 2) complete('retryable') under the cap stays retryable; page + run untouched.
  perform public.complete_inbox_agent_execution(exec_under, 'retryable', 'temporary blip');
  if not exists (select 1 from public.inbox_agent_executions where id=exec_under and state='retryable') then
    raise exception 'FAIL: under-cap execution should stay retryable'; end if;
  if not exists (select 1 from public.email_scan_runs where id=run_under and status='running') then
    raise exception 'FAIL: under-cap run should stay running'; end if;

  -- 3) backstop reaper fails a spent 'retryable' execution; page + run finalize.
  perform public.recover_exhausted_inbox_agent_retries();
  if not exists (select 1 from public.inbox_agent_executions where id=exec_backstop and state='failed') then
    raise exception 'FAIL: backstop did not fail spent retryable execution'; end if;
  if not exists (select 1 from public.email_scan_runs where id=run_backstop and status='failed') then
    raise exception 'FAIL: backstop did not finalize the run'; end if;

  -- idempotent second pass
  perform public.recover_exhausted_inbox_agent_retries();
  if not exists (select 1 from public.email_scan_runs where id=run_under and status='running') then
    raise exception 'FAIL: second pass disturbed a healthy run'; end if;

  raise notice 'ALL ASSERTIONS PASSED';
end $$;

rollback;
