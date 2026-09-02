-- Run against development only. Creates short-lived fixtures and rolls everything back. Exercises the
-- rollup from 202609020001: at most ONE pending review card per (user, canonical_merchant_key), so
-- the inbox stops showing the same subscription twice. Asserts the consolidation merge (higher
-- confidence wins a field, a null never erases a known value), that the partial index rejects a second
-- pending card but ignores resolved ones, and that the worker's actual upsert merges instead of
-- erroring.
--
-- Assumes the migration has been applied (the index exists). Run after `supabase db push`.
--
-- To exercise the consolidation path the fixture must contain colliding rows, which the live index
-- forbids — so the test drops the index, seeds the collision, merges, and rebuilds it, mirroring the
-- migration's own order and proving the claim that the index is only creatable after the merge. All
-- of it is inside the transaction and rolled back, restoring the real index; development only.
begin;

do $$
declare
  u uuid := gen_random_uuid();
  run_old uuid := gen_random_uuid();
  run_new uuid := gen_random_uuid();
  e_old uuid; e_new uuid; e_res uuid; e_dup uuid; e_up uuid;
  r record; n int;
begin
  -- Rolled back with everything else.
  execute 'drop index if exists public.subscription_candidates_pending_merchant_key';

  insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values (u, 'authenticated', 'authenticated', 'dedupe-' || u || '@test.invalid', 'not-a-login', now(),
          '{"provider":"email","providers":["email"]}', '{}', now(), now());

  insert into public.email_scan_runs (id, user_id, provider, status, started_at)
  values (run_old, u, 'google', 'completed', now() - interval '2 hours'),
         (run_new, u, 'google', 'completed', now());

  insert into public.detected_billing_events
    (user_id, scan_run_id, provider, provider_message_id, event_type, merchant_name, confidence,
     evidence, source_received_at)
  values (u, run_old, 'google', 'msg-old', 'created', 'Zeta', 0.9, 'a', now()) returning id into e_old;
  insert into public.detected_billing_events
    (user_id, scan_run_id, provider, provider_message_id, event_type, merchant_name, confidence,
     evidence, source_received_at)
  values (u, run_new, 'google', 'msg-new', 'created', 'Zeta', 0.8, 'b', now()) returning id into e_new;
  insert into public.detected_billing_events
    (user_id, scan_run_id, provider, provider_message_id, event_type, merchant_name, confidence,
     evidence, source_received_at)
  values (u, run_old, 'google', 'msg-res', 'created', 'Res', 0.7, 'c', now()) returning id into e_res;

  -- Two pending cards for one merchant across two runs — the cross-run stacking the inbox showed.
  -- The MORE confident row lacks the amount; the less confident one knows it.
  insert into public.subscription_candidates
    (user_id, scan_run_id, detected_event_id, suggested_action, merchant_name, canonical_merchant_key,
     currency, billing_cycle, event_type, confidence, evidence)
  values (u, run_old, e_old, 'add', 'Zeta', 'zeta', 'USD', 'monthly', 'created', 0.9, 'a');
  insert into public.subscription_candidates
    (user_id, scan_run_id, detected_event_id, suggested_action, merchant_name, canonical_merchant_key,
     amount, event_type, confidence, evidence)
  values (u, run_new, e_new, 'add', 'Zeta (Pro)', 'zeta', 42.00, 'created', 0.8, 'b');
  -- A resolved card, which the partial index must ignore entirely.
  insert into public.subscription_candidates
    (user_id, scan_run_id, detected_event_id, suggested_action, merchant_name, canonical_merchant_key,
     event_type, confidence, evidence, review_status)
  values (u, run_old, e_res, 'add', 'Res', 'res', 'created', 0.7, 'c', 'ignored');

  ------------------------------------------------------------------ consolidation
  -- Re-run the migration's merge over this fixture (the index already forbids new collisions, so the
  -- pre-existing pair is inserted above before it applies to them).
  create temporary table _t_merge on commit drop as
  with ranked as (
    select c.id, c.user_id, c.canonical_merchant_key, c.scan_run_id, c.amount, c.currency,
           c.billing_cycle, c.renewal_date, c.matched_subscription_id,
           nullif(c.evidence,'') as evidence, c.confidence,
           -- Alias is `sr`, not `r`: `r` is the record variable declared above and plpgsql would
           -- resolve `r.started_at` against it rather than the table.
           row_number() over (partition by c.user_id, c.canonical_merchant_key
             order by sr.started_at desc nulls last, c.created_at desc, c.id desc) as run_rn,
           row_number() over (partition by c.user_id, c.canonical_merchant_key
             order by c.confidence desc, c.created_at asc, c.id asc) as rn
    from public.subscription_candidates c
    join public.email_scan_runs sr on sr.id = c.scan_run_id
    where c.review_status = 'pending'
  )
  select (array_agg(id order by rn))[1] as survivor_id, user_id, canonical_merchant_key,
         (array_agg(scan_run_id order by run_rn))[1] as scan_run_id,
         (array_agg(amount order by rn) filter (where amount is not null))[1] as amount,
         (array_agg(currency order by rn) filter (where currency is not null))[1] as currency,
         (array_agg(billing_cycle order by rn) filter (where billing_cycle is not null))[1] as billing_cycle,
         (array_agg(renewal_date order by rn) filter (where renewal_date is not null))[1] as renewal_date,
         (array_agg(matched_subscription_id order by rn)
            filter (where matched_subscription_id is not null))[1] as matched_subscription_id,
         (array_agg(evidence order by rn) filter (where evidence is not null))[1] as evidence,
         max(confidence) as confidence
  from ranked group by user_id, canonical_merchant_key having count(*) > 1;

  update public.subscription_candidates c
  set amount=m.amount, currency=m.currency, billing_cycle=m.billing_cycle, renewal_date=m.renewal_date,
      matched_subscription_id=m.matched_subscription_id, evidence=coalesce(m.evidence,''),
      confidence=m.confidence, scan_run_id=m.scan_run_id,
      suggested_action = case when m.matched_subscription_id is not null then 'review' else c.suggested_action end
  from _t_merge m where c.id = m.survivor_id;

  delete from public.subscription_candidates c using _t_merge m
  where c.user_id=m.user_id and c.canonical_merchant_key=m.canonical_merchant_key
    and c.review_status='pending' and c.id <> m.survivor_id;

  select count(*) into n from public.subscription_candidates where user_id=u and canonical_merchant_key='zeta';
  if n <> 1 then raise exception 'expected 1 merged card, got %', n; end if;

  select * into r from public.subscription_candidates where user_id=u and canonical_merchant_key='zeta';
  if r.merchant_name <> 'Zeta' then raise exception 'higher-confidence name must win, got %', r.merchant_name; end if;
  if r.amount is distinct from 42.00 then raise exception 'gap must be filled from the lower-confidence row, got %', r.amount; end if;
  if r.currency <> 'USD' then raise exception 'currency must survive the merge, got %', r.currency; end if;
  if r.billing_cycle::text <> 'monthly' then raise exception 'billing_cycle must survive, got %', r.billing_cycle; end if;
  if r.confidence <> 0.9 then raise exception 'confidence must be the max, got %', r.confidence; end if;
  if r.scan_run_id <> run_new then raise exception 'merged card must belong to the newest run'; end if;
  if (select count(*) from public.subscription_candidates
       where user_id=u and canonical_merchant_key='res' and review_status='ignored') <> 1
    then raise exception 'a resolved card must survive consolidation'; end if;

  ------------------------------------------------------------------ the index holds
  -- Only creatable now that the duplicates are merged — the migration's ordering claim.
  execute 'create unique index subscription_candidates_pending_merchant_key
             on public.subscription_candidates (user_id, canonical_merchant_key)
             where review_status = ''pending''';

  insert into public.detected_billing_events
    (user_id, scan_run_id, provider, provider_message_id, event_type, merchant_name, confidence,
     evidence, source_received_at)
  values (u, run_new, 'google', 'msg-dup', 'created', 'Zeta', 0.5, 'd', now()) returning id into e_dup;
  begin
    insert into public.subscription_candidates
      (user_id, scan_run_id, detected_event_id, suggested_action, merchant_name,
       canonical_merchant_key, event_type, confidence, evidence)
    values (u, run_new, e_dup, 'add', 'Zeta Again', 'zeta', 'created', 0.5, 'd');
    raise exception 'index failed to reject a duplicate pending card';
  exception when unique_violation then null;
  end;

  -- A resolved card must NOT block a fresh proposal for that merchant.
  insert into public.subscription_candidates
    (user_id, scan_run_id, detected_event_id, suggested_action, merchant_name, canonical_merchant_key,
     event_type, confidence, evidence)
  values (u, run_new, e_dup, 'add', 'Res', 'res', 'created', 0.6, 'd');
  select count(*) into n from public.subscription_candidates where user_id=u and canonical_merchant_key='res';
  if n <> 2 then raise exception 'a resolved card must not block re-proposal, got % rows', n; end if;

  ------------------------------------------------------------------ the worker's upsert merges
  insert into public.detected_billing_events
    (user_id, scan_run_id, provider, provider_message_id, event_type, merchant_name, confidence,
     evidence, source_received_at)
  values (u, run_new, 'google', 'msg-up', 'created', 'Zeta', 0.99, 'f', now()) returning id into e_up;

  insert into public.subscription_candidates as c
    (user_id, scan_run_id, detected_event_id, matched_subscription_id, suggested_action,
     merchant_name, canonical_merchant_key, amount, currency, billing_cycle, renewal_date,
     category, event_type, confidence, evidence, resolution_reason)
  values (u, run_new, e_up, null, 'add', 'Zeta Premium', 'zeta', null, null, null, null,
          'other', 'created', 0.99, 'f', 'agentic_proposal')
  on conflict (user_id, canonical_merchant_key) where review_status = 'pending' do update set
    scan_run_id = excluded.scan_run_id,
    merchant_name = case when excluded.confidence > c.confidence
      then coalesce(excluded.merchant_name, c.merchant_name) else coalesce(c.merchant_name, excluded.merchant_name) end,
    amount = case when excluded.confidence > c.confidence
      then coalesce(excluded.amount, c.amount) else coalesce(c.amount, excluded.amount) end,
    currency = case when excluded.confidence > c.confidence
      then coalesce(excluded.currency, c.currency) else coalesce(c.currency, excluded.currency) end,
    confidence = greatest(c.confidence, excluded.confidence);

  select count(*) into n from public.subscription_candidates where user_id=u and canonical_merchant_key='zeta';
  if n <> 1 then raise exception 'upsert must merge, got % cards', n; end if;
  select * into r from public.subscription_candidates where user_id=u and canonical_merchant_key='zeta';
  if r.merchant_name <> 'Zeta Premium' then raise exception 'the more confident name must win, got %', r.merchant_name; end if;
  if r.amount is distinct from 42.00 then raise exception 'a null must not erase a known amount, got %', r.amount; end if;
  if r.currency <> 'USD' then raise exception 'a null must not erase a known currency, got %', r.currency; end if;

  raise notice 'one_pending_card_per_merchant: all assertions passed';
end $$;

rollback;
