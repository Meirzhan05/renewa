## Why

The inbox agent surfaces the same real subscription as multiple review cards. In the latest run the
user saw five cards for three subscriptions: `Anthropic` + `Anthropic (Claude Pro)` (both USD 20
monthly) and `ChatGPT Plus` + `OpenAI (ChatGPT Plus)`. Each pair is one vendor billing from one
registrable sender domain, split into two cards because the model chose a different display name on
two different emails.

The cause is that merchant *identity* is derived from merchant *display name*:
`canonicalMerchantKey(merchant_name)` slugs whatever label the model produced. Every dedup layer in
the system keys on that slug — the in-page `tracked` set, `dedupeProposal`'s tracked/suppressed sets,
and the bridge's suppression and subscription matching — so one inconsistent naming decision defeats
all of them at once. The review queue is the product's core surface; duplicates there make the agent
look unreliable and force the user to resolve the same subscription twice.

## What Changes

- Derive a proposal's canonical merchant key from the **registrable sender domain** of its evidence
  email (e.g. `anthropic.com` → `anthropic`) instead of from the model-chosen display name, so the
  same vendor resolves to one identity regardless of how the model labelled it.
- Keep an explicit **aggregator fallback**: for shared billing domains (Apple, Google, PayPal,
  Stripe, Paddle and similar) the sender identifies the *processor*, not the merchant, so those fall
  back to name-derived identity rather than collapsing unrelated subscriptions into one card.
- Roll up the review queue so a user has **one pending card per merchant identity**, merging later
  evidence into the existing card instead of inserting a second one. Evidence records
  (`detected_billing_events`) remain one-per-email and are unchanged.
- Enforce the rollup in the database with a partial uniqueness constraint on
  `(user_id, canonical_merchant_key)` over pending rows, so neither concurrent pages nor a later scan
  can add a second card for a merchant. The scope is the pending queue rather than a single run
  because that is what the inbox displays — it selects by user and review status, never by run.
- Consolidate pending cards that already collide under that key so the constraint can be applied.
  Cards written before this change keep their old name-derived keys and are not re-identified, so the
  duplicates now on screen remain until resolved once; new scans are correct from the first run.

## Capabilities

### New Capabilities
- `merchant-identity-resolution`: how a stable canonical merchant key is derived for a proposal —
  sender-domain-first, aggregator-aware, with a deterministic fallback — so one vendor yields one
  identity across differing model-chosen display names.
- `proposal-review-rollup`: the review queue surfaces one candidate per merchant identity per scan
  run, merging concurrent and later evidence into that single card rather than appending duplicates.

### Modified Capabilities
- `subscription-proposal-gate`: the deterministic dedup guard currently only rejects proposals that
  *exact-match* an already tracked or suppressed item. It must also collapse same-merchant proposals
  raised within a single run under different display names, and must operate across pages that do not
  share in-process state.

## Impact

- `worker/src/domain/email.ts` — merchant key derivation gains a sender-domain path and the
  aggregator domain set; `senderLabel` already exists here and is the basis for the new derivation.
- `worker/src/agent/propose.ts` — `validateProposal` must resolve identity with evidence context
  rather than from `merchant_name` alone.
- `worker/src/agent/candidate-bridge.ts` — the write boundary becomes the rollup point: upsert one
  candidate per `(scan_run_id, canonical_merchant_key)` and merge fields on conflict.
- `worker/src/managed/page-analysis.ts` — passes the page's messages so the bridge can map an
  evidence ref back to its sender.
- New Supabase migration — partial unique index on `subscription_candidates (user_id,
  canonical_merchant_key) where review_status = 'pending'`, plus a merge of any colliding pending rows.
- Behaviour change only in the review queue; no iOS client change is required, and
  `detected_billing_events` keeps its existing per-email grain and conflict key.
