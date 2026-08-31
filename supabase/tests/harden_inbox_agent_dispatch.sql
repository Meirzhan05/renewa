-- Run against development only. The transaction creates short-lived auth and mailbox fixtures and
-- rolls everything back. It exercises reservation safety/fairness, cancellation exclusion, and
-- both expiry outcomes without touching real discoveries.
begin;

do $$
declare
  a uuid := gen_random_uuid();
  b uuid := gen_random_uuid();
  run_a uuid := gen_random_uuid();
  run_b uuid := gen_random_uuid();
  run_cancelled uuid := gen_random_uuid();
  run_expiry uuid := gen_random_uuid();
  conn_a uuid := gen_random_uuid();
  conn_b uuid := gen_random_uuid();
  job_a1 uuid := gen_random_uuid();
  job_a2 uuid := gen_random_uuid();
  job_b1 uuid := gen_random_uuid();
  job_cancelled uuid := gen_random_uuid();
  job_expiry uuid := gen_random_uuid();
  selected_count integer;
  selected_users integer;
  cancelled_selected integer;
  expiry_execution uuid;
begin
  insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values
    (a, 'authenticated', 'authenticated', 'dispatch-a-' || a || '@test.invalid', 'not-a-login', now(), '{"provider":"email","providers":["email"]}', '{}', now(), now()),
    (b, 'authenticated', 'authenticated', 'dispatch-b-' || b || '@test.invalid', 'not-a-login', now(), '{"provider":"email","providers":["email"]}', '{}', now(), now());
  insert into public.email_connections (id, user_id, provider, email, encrypted_tokens)
  values (conn_a, a, 'google', 'a@test.invalid', 'fixture'),
         (conn_b, b, 'google', 'b@test.invalid', 'fixture');
  insert into public.email_scan_runs (id, user_id, provider, status, stage, batch_id, started_at)
  values (run_a, a, 'google', 'running', 'reasoning', gen_random_uuid(), now()),
         (run_b, b, 'google', 'running', 'reasoning', gen_random_uuid(), now()),
         (run_cancelled, a, 'google', 'running', 'reasoning', gen_random_uuid(), now()),
         (run_expiry, b, 'google', 'running', 'reasoning', gen_random_uuid(), now());
  update public.email_scan_runs set cancel_requested_at = now() where id = run_cancelled;
  insert into public.scan_jobs (id, user_id, provider, status, scan_run_id, batch_id, connection_id, created_at)
  values (job_a1, a, 'google', 'pending', run_a, gen_random_uuid(), conn_a, now() - interval '1 hour'),
         (job_a2, a, 'google', 'pending', run_a, gen_random_uuid(), conn_a, now() - interval '1 hour'),
         (job_b1, b, 'google', 'pending', run_b, gen_random_uuid(), conn_b, now() - interval '1 hour'),
         (job_cancelled, a, 'google', 'pending', run_cancelled, gen_random_uuid(), conn_a, now() - interval '2 hours'),
         (job_expiry, b, 'google', 'pending', run_expiry, gen_random_uuid(), conn_b, now() - interval '30 minutes');
  insert into public.inbox_agent_executions (user_id, scan_run_id, scan_job_id, connection_id, task_kind, idempotency_key, created_at)
  values (a, run_a, job_a1, conn_a, 'page_analysis', 'dispatch-test-a1-' || job_a1, now() - interval '1 hour'),
         (a, run_a, job_a2, conn_a, 'page_analysis', 'dispatch-test-a2-' || job_a2, now() - interval '1 hour'),
         (b, run_b, job_b1, conn_b, 'page_analysis', 'dispatch-test-b1-' || job_b1, now() - interval '1 hour'),
         (a, run_cancelled, job_cancelled, conn_a, 'page_analysis', 'dispatch-test-c-' || job_cancelled, now() - interval '2 hours'),
         (b, run_expiry, job_expiry, conn_b, 'page_analysis', 'dispatch-test-e-' || job_expiry, now() - interval '30 minutes');

  perform public.reserve_inbox_agent_executions(2, 100, 100, 100, 1, 120);
  select count(*), count(distinct user_id) into selected_count, selected_users
  from public.inbox_agent_executions where scan_job_id in (job_a1, job_a2, job_b1) and state = 'leased';
  if selected_count <> 2 or selected_users <> 2 then
    raise exception 'fair reservation failed: %, %', selected_count, selected_users;
  end if;
  -- A second dispatcher pass must not re-lease either row claimed by the first pass.
  perform public.reserve_inbox_agent_executions(2, 100, 100, 100, 1, 120);
  if (select count(*) from public.inbox_agent_executions
      where scan_job_id in (job_a1, job_a2, job_b1) and state = 'leased') <> 2 then
    raise exception 'overlapping reservation changed an existing lease';
  end if;
  select count(*) into cancelled_selected from public.inbox_agent_executions where scan_job_id = job_cancelled and state = 'leased';
  if cancelled_selected <> 0 then raise exception 'cancelled work was reserved'; end if;

  select id into expiry_execution from public.inbox_agent_executions where scan_job_id = job_expiry;
  update public.inbox_agent_executions set state = 'leased', dispatch_token = gen_random_uuid(), dispatch_attempt = 1,
      dispatch_expires_at = now() - interval '1 second', lease_expires_at = now() - interval '1 second'
  where id = expiry_execution;
  perform public.recover_expired_inbox_agent_executions();
  if not exists (select 1 from public.inbox_agent_executions where id = expiry_execution and state = 'retryable') then
    raise exception 'expired reservation was not made retryable';
  end if;
  update public.inbox_agent_executions set state = 'leased', dispatch_attempt = 3,
      dispatch_expires_at = now() - interval '1 second', lease_expires_at = now() - interval '1 second'
  where id = expiry_execution;
  perform public.recover_expired_inbox_agent_executions();
  if not exists (select 1 from public.inbox_agent_executions where id = expiry_execution and state = 'failed') then
    raise exception 'exhausted reservation was not failed';
  end if;
end $$;

rollback;
