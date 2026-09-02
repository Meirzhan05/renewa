## 1. Merchant identity resolution (pure domain)

- [x] 1.1 Add an `AGGREGATOR_DOMAINS` set to `worker/src/domain/email.ts` covering shared billing
      senders (Apple, Google Play, PayPal, Stripe, Paddle, Chargebee, Microsoft store) with a comment
      explaining why an unlisted aggregator must fail safe toward duplicates, never over-merge.
- [x] 1.2 Add `resolveMerchantIdentity(sender, displayName)` to `worker/src/domain/email.ts`: use the
      registrable label from the sender domain when it is parseable and not an aggregator, otherwise
      `canonicalMerchantKey(displayName)`, otherwise the `unknown-merchant` sentinel. Keep it pure.
- [x] 1.3 Unit-test `resolveMerchantIdentity` in `worker/test/`: the two observed pairs collapse
      (`mail.anthropic.com` variants; `email.openai.com` vs `tm.openai.com`), distinct vendors stay
      distinct, Apple receipts for different merchants stay distinct, unparseable sender falls back to
      the name, and no-sender-no-name yields the sentinel.

## 2. Roll the review queue up at the write boundary

- [x] 2.1 Extend `BridgeInput` in `worker/src/agent/candidate-bridge.ts` with a `messageSenders`
      lookup (`messageId -> sender`) and resolve each proposal's identity from
      `evidence_refs[0]` via `resolveMerchantIdentity`, falling back to the proposal's own
      `merchant_key` when the ref has no matching message.
- [x] 2.2 Use the resolved identity (not `p.merchant_key`) for the suppression check and the
      tracked-subscription match, so a suppressed merchant stays suppressed under a new label.
- [x] 2.3 Change the `subscription_candidates` insert to upsert on
      `(user_id, canonical_merchant_key) where review_status = 'pending'` with the merge rule from the
      design: higher confidence supplies the identity-bearing fields, `coalesce` prevents a null
      overwriting a known value, `confidence` takes the max, and `suggested_action` is recomputed from
      `matched_subscription_id`. Guard SQLSTATE 23505 so a shared `detected_event_id` skips that
      proposal (as `on conflict (detected_event_id) do nothing` did) rather than failing the page.
- [x] 2.4 Keep the `detected_billing_events` insert exactly as it is (per-email grain, existing
      conflict key) and confirm the returned count still reports cards surfaced, not events written.
- [x] 2.5 Pass `messageSenders` from `bridgeInboxProposals` in
      `worker/src/managed/page-analysis.ts`, built from `job.rawMessages` (`MailMetadata` already
      carries `id` and `sender`) — no new fetch.

## 3. Database constraint and consolidation

- [x] 3.1 Write a Supabase migration that, in one transaction, consolidates pending
      `subscription_candidates` colliding on `(user_id, canonical_merchant_key)`: survivor is the
      highest-confidence row, non-null fields fold in from the losers, the survivor takes the newest
      run (ranked by the run's `started_at`, not the row's `created_at`, which ties), losers deleted.
- [x] 3.2 In the same migration and after the merge, create the partial unique index on
      `subscription_candidates (user_id, canonical_merchant_key) where review_status = 'pending'`.
- [x] 3.3 Add a `supabase/tests/` script asserting the merge and constraint: duplicates collapse to
      one card, a resolved decision survives consolidation, non-null fields are preserved, and a
      second insert for the same identity merges rather than erroring.

## 4. Tighten the in-page gate (optimization)

- [x] 4.1 Resolve identity in `worker/src/agent/propose.ts` so the in-page `tracked` set and
      `dedupeProposal` key on merchant identity, keeping `merchant_name` as the display field and
      leaving the typed proposal contract and anti-exfiltration bounds unchanged.
- [x] 4.2 Extend the propose/dedup tests to cover a same-vendor-different-name pair being rejected as
      `duplicate_tracked` within one page.

## 5. Verify

- [x] 5.1 Run `npm run typecheck` and the worker test suite in `worker/`; all green.
- [x] 5.2 Validate the migration against the live schema inside `BEGIN … ROLLBACK` (seed the observed
      duplicate pairs, assert one card per identity, assert the index rejects a duplicate).
- [x] 5.3 Run `openspec validate dedupe-inbox-proposals-by-merchant`.
- [ ] 5.4 After deploy, re-scan the reference inbox and confirm the queue shows one card each for
      Anthropic, ChatGPT Plus, and Uber One — five cards become three — with no card losing its
      amount or billing cycle.
