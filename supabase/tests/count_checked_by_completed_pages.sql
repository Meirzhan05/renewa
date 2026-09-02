-- Run against development only. Creates short-lived fixtures and rolls everything back. Exercises the
-- completed-only progress rule from 202609010001: "emails checked" = SUM(scan_jobs.message_count)
-- over COMPLETED pages, so the counter tracks agent processing (not fetcher enqueue). Asserts the live
-- email_scan_batch_progress endpoint and the finalize_email_scan_run_if_drained denorm, including that
-- all-completed converges to the full inbox size and a run with a failed page honestly reports less.
begin;

do $$
declare
  u uuid := gen_random_uuid();
  run_mixed  uuid := gen_random_uuid();  -- 2 completed + running + pending + failed  -> 200 (not 500)
  run_alldone uuid := gen_random_uuid();  -- 3 completed                               -> 300 (full)
  run_failed uuid := gen_random_uuid();  -- 2 completed + 1 failed, drained            -> 200 (< 300)
  run_cancel uuid := gen_random_uuid();  -- 1 completed + 1 failed, cancel-requested   -> 100, cancelled
  b_mixed uuid := gen_random_uuid();
  m bigint; l bigint; d bigint; st text; cm bigint;
begin
  insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (u, 'authenticated', 'authenticated', 'checked-' || u || '@test.invalid', 'not-a-login', now(),
          '{"provider":"email","providers":["email"]}', '{}', now(), now());

  insert into public.email_scan_runs (id, user_id, provider, status, stage, batch_id, started_at)
  values (run_mixed,   u, 'google', 'running', 'reasoning', b_mixed,           now()),
         (run_alldone, u, 'google', 'running', 'reasoning', gen_random_uuid(), now()),
         (run_failed,  u, 'google', 'running', 'reasoning', gen_random_uuid(), now());
  insert into public.email_scan_runs (id, user_id, provider, status, stage, batch_id, started_at, cancel_requested_at)
  values (run_cancel,  u, 'google', 'running', 'reasoning', gen_random_uuid(), now(), now());

  insert into public.scan_jobs (user_id, provider, scan_run_id, status, message_count, triage_look_count, raw_messages)
  values
    -- run_mixed: only the two completed pages count toward "checked"
    (u, 'google', run_mixed,   'completed', 100, 7,   '[]'::jsonb),
    (u, 'google', run_mixed,   'completed', 100, 7,   '[]'::jsonb),
    (u, 'google', run_mixed,   'running',   100, null, '[]'::jsonb),
    (u, 'google', run_mixed,   'pending',   100, null, '[]'::jsonb),
    (u, 'google', run_mixed,   'failed',    100, null, '[]'::jsonb),
    -- run_alldone: every page completed -> converges to full inbox size
    (u, 'google', run_alldone, 'completed', 100, 2,   '[]'::jsonb),
    (u, 'google', run_alldone, 'completed', 100, 2,   '[]'::jsonb),
    (u, 'google', run_alldone, 'completed', 100, 2,   '[]'::jsonb),
    -- run_failed: drained with a failed page -> counts completed only
    (u, 'google', run_failed,  'completed', 100, 5,   '[]'::jsonb),
    (u, 'google', run_failed,  'completed', 100, 5,   '[]'::jsonb),
    (u, 'google', run_failed,  'failed',    100, null, '[]'::jsonb),
    -- run_cancel: cancel-requested, drained -> cancel wins, counts completed only
    (u, 'google', run_cancel,  'completed', 100, 3,   '[]'::jsonb),
    (u, 'google', run_cancel,  'failed',    100, null, '[]'::jsonb);

  -- Live endpoint: completed-only messages_scanned; likely_billing (triage) unchanged; detected = 0.
  select messages_scanned, likely_billing, detected into m, l, d
  from public.email_scan_batch_progress(u, b_mixed);
  assert m = 200, format('run_mixed messages_scanned expected 200 (completed only, all-rows=500) got %s', m);
  assert l = 14,  format('run_mixed likely_billing expected 14 (unchanged) got %s', l);
  assert d = 0,   format('run_mixed detected expected 0 got %s', d);

  -- Finalize: all-completed converges to the full inbox size.
  perform public.finalize_email_scan_run_if_drained(run_alldone);
  select status, messages_scanned into st, m from public.email_scan_runs where id = run_alldone;
  assert st = 'completed', format('run_alldone status expected completed got %s', st);
  assert m = 300, format('run_alldone messages_scanned expected 300 (full inbox) got %s', m);

  -- Finalize: a failed page -> run honestly reports fewer than the full enqueued inbox.
  perform public.finalize_email_scan_run_if_drained(run_failed);
  select status, messages_scanned, candidate_messages into st, m, cm from public.email_scan_runs where id = run_failed;
  assert st = 'failed', format('run_failed status expected failed got %s', st);
  assert m = 200, format('run_failed messages_scanned expected 200 (< 300 full, completed only) got %s', m);
  assert cm = 10, format('run_failed candidate_messages expected 10 got %s', cm);

  -- Finalize: cancel precedence preserved; still completed-only count.
  perform public.finalize_email_scan_run_if_drained(run_cancel);
  select status, messages_scanned into st, m from public.email_scan_runs where id = run_cancel;
  assert st = 'cancelled', format('run_cancel status expected cancelled (cancel wins) got %s', st);
  assert m = 100, format('run_cancel messages_scanned expected 100 (completed only) got %s', m);

  raise notice 'count_checked_by_completed_pages: all assertions passed';
end $$;

rollback;
