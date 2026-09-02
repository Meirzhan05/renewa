-- The inbox agent surfaced the same subscription as several review cards. Observed in one run:
-- "Anthropic" + "Anthropic (Claude Pro)" (both USD 20/monthly) and "ChatGPT Plus" +
-- "OpenAI (ChatGPT Plus)" — five cards for three subscriptions.
--
-- Cause: merchant identity was slugged from the display name the model chose, so one vendor named two
-- ways became two identities and defeated every dedup layer at once. The worker now derives identity
-- from the evidence sender's registrable domain (resolveMerchantIdentity), which is stable across a
-- vendor's mail. This migration adds the durable half of that fix.
--
-- Scope is (user_id, canonical_merchant_key) among PENDING rows, NOT (scan_run_id, ...): the inbox
-- queries subscription_candidates by user + review_status with no run filter, so a per-run invariant
-- would be invisible to the user and every later scan would stack another card for the same merchant.
-- Restricting the index to pending rows keeps resolved history intact and still lets a merchant be
-- re-proposed after the user resolves it (re-surfacing is governed by merchant_discovery_suppressions,
-- not by this index).
--
-- Enforced in the database because pages are analysed concurrently and share no in-process state — a
-- read-then-insert in application code has a real interleaving window.
--
-- No re-keying of historical rows: cards written before this change keep their name-derived keys, so
-- the pre-existing duplicates stay until the user resolves them once. Deliberate — re-deriving old
-- identities would mean a second copy of the aggregator and public-suffix rules that would drift from
-- the worker's.

-- 1) Consolidate any pending cards that ALREADY collide under the new index, so it can be created.
--    A no-op on data where no such collision exists; required for safety because a run that completed
--    before deploy can leave a same-key pending card in a second run.
create temporary table _pending_card_merge on commit drop as
with ranked as (
  select
    c.id, c.user_id, c.canonical_merchant_key, c.scan_run_id, c.amount, c.currency, c.billing_cycle,
    c.renewal_date, c.matched_subscription_id, nullif(c.evidence, '') as evidence, c.confidence,
    -- Rank the owning RUN, not the row's created_at: candidates written in one transaction share a
    -- created_at, which would make "newest run" a nondeterministic tie.
    row_number() over (
      partition by c.user_id, c.canonical_merchant_key
      order by r.started_at desc nulls last, c.created_at desc, c.id desc
    ) as run_rn,
    row_number() over (
      partition by c.user_id, c.canonical_merchant_key
      -- Most confident wins; oldest then id keep it deterministic.
      order by c.confidence desc, c.created_at asc, c.id asc
    ) as rn
  from public.subscription_candidates c
  join public.email_scan_runs r on r.id = c.scan_run_id
  where c.review_status = 'pending'
)
select
  (array_agg(id order by rn))[1]                                                  as survivor_id,
  user_id,
  canonical_merchant_key,
  -- Newest run: the surviving card belongs to the most recent scan that saw this merchant.
  (array_agg(scan_run_id order by run_rn))[1]                                     as scan_run_id,
  -- Rank order = confidence order, so the first non-null is the most confident known value. A null
  -- never erases a value another row knows.
  (array_agg(amount order by rn) filter (where amount is not null))[1]            as amount,
  (array_agg(currency order by rn) filter (where currency is not null))[1]        as currency,
  (array_agg(billing_cycle order by rn) filter (where billing_cycle is not null))[1] as billing_cycle,
  (array_agg(renewal_date order by rn) filter (where renewal_date is not null))[1]   as renewal_date,
  (array_agg(matched_subscription_id order by rn)
     filter (where matched_subscription_id is not null))[1]                       as matched_subscription_id,
  (array_agg(evidence order by rn) filter (where evidence is not null))[1]        as evidence,
  max(confidence)                                                                as confidence
from ranked
group by user_id, canonical_merchant_key
having count(*) > 1;

update public.subscription_candidates c
set amount                  = m.amount,
    currency                = m.currency,
    billing_cycle           = m.billing_cycle,
    renewal_date            = m.renewal_date,
    matched_subscription_id = m.matched_subscription_id,
    evidence                = coalesce(m.evidence, ''),
    confidence              = m.confidence,
    scan_run_id             = m.scan_run_id,
    -- Keep the action consistent with the match the merged card ended up carrying.
    suggested_action        = case when m.matched_subscription_id is not null
                                   then 'review' else c.suggested_action end
from _pending_card_merge m
where c.id = m.survivor_id;

delete from public.subscription_candidates c
using _pending_card_merge m
where c.user_id = m.user_id
  and c.canonical_merchant_key = m.canonical_merchant_key
  and c.review_status = 'pending'
  and c.id <> m.survivor_id;

-- 2) The invariant itself. Must follow the merge above — a unique index cannot be built while
--    duplicates exist.
create unique index if not exists subscription_candidates_pending_merchant_key
  on public.subscription_candidates (user_id, canonical_merchant_key)
  where review_status = 'pending';
