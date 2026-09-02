## Context

Merchant identity is currently `canonicalMerchantKey(merchant_name)` — a slug of whatever display
name the model produced (`worker/src/agent/propose.ts:44`). That single string is the dedup key for
every layer in the pipeline:

```
propose.ts        tracked.add(merchant_key)          in-page, in-memory
propose.ts        dedupeProposal(tracked/suppressed) cross-run, from DB
candidate-bridge  suppressedKeys / subByKey          write boundary
```

Because identity is downstream of a free-text label, one inconsistent naming decision defeats all
three at once. Observed in the latest run:

| Card | Evidence sender | Key today |
|---|---|---|
| `Anthropic` | `mail.anthropic.com` | `anthropic` |
| `Anthropic (Claude Pro)` | `mail.anthropic.com` | `anthropic-claude-pro` |
| `ChatGPT Plus` | `email.openai.com` | `chatgpt-plus` |
| `OpenAI (ChatGPT Plus)` | `tm.openai.com` | `openai-chatgpt-plus` |

Two structural facts make this worse than a naming nit:

1. **Pages are isolated.** Since the move to `MemorySaver`, each page's graph state is in-process
   only. The in-page `tracked` set cannot see sibling pages, so the only shared choke point is the
   database.
2. **Neither DB conflict key is merchant identity.** `detected_billing_events` conflicts on
   `(user_id, provider, provider_message_id, event_type)` — per email. `subscription_candidates`
   conflicts on `detected_event_id` — per evidence. Nothing collapses two evidence rows for one
   merchant into one card.

The two duplicate pairs came from four *distinct* emails, so both failure modes are live at once:
divergent names produce divergent keys, and the emails landed on different pages.

## Goals / Non-Goals

**Goals:**
- One review card per real subscription per scan run.
- Merchant identity that is stable against the model's naming variance.
- Correctness that does not depend on pages sharing memory.
- Consolidate duplicates already sitting in existing runs.

**Non-Goals:**
- General fuzzy merchant resolution (embeddings, edit distance, a merchant registry). Out of scope;
  the sender domain is a strong, cheap signal that covers the observed failures.
- Changing evidence grain. `detected_billing_events` stays one-per-email.
- Re-keying cards written before this change. They keep their name-derived keys and the user resolves
  the existing duplicates once; see Migration Plan.
- Any iOS client change. The queue shrinks; the card contract is unchanged.

> **Revised during implementation.** "Cross-run card merging" was originally a Non-Goal, on the
> assumption that the review queue is scoped to a run. It is not: `email-scan/index.ts:1153` selects
> candidates by `user_id` + `review_status = 'pending'` with no run filter, so every scan would stack
> another card per merchant and the user would see them all. Cross-run merging is therefore a Goal,
> and the uniqueness scope changed accordingly (Decision 3).

## Decisions

### 1. Identity from the registrable sender domain, not the display name

`senderLabel()` already exists in `worker/src/domain/email.ts:115` and returns the registrable-ish
label (`anthropic` from `billing.anthropic.com`). Identity becomes a new
`resolveMerchantIdentity(senderDomain, displayName)` in the same module, keeping derivation pure and
unit-testable.

*Why over alternatives:* matching on normalized display names (strip parentheticals, compare
prefixes) is guesswork that would merge `Google One` with `Google Cloud`. The sender domain is
declared by the vendor, stable across their emails, and already parsed here. It fixes both observed
pairs exactly — including the `email.openai.com` vs `tm.openai.com` subdomain case, which no
name-based heuristic would catch.

### 2. Aggregator domains fall back to name-derived identity

The sender is only a merchant proxy when the vendor bills directly. For Apple, Google Play, PayPal,
Stripe, Paddle, Chargebee and similar, one domain fronts many merchants — keying on it would merge
every App Store subscription into one card. That is a *worse* bug than the one being fixed, so
identity falls back to `canonicalMerchantKey(displayName)` for a configured aggregator set.

*Why a static denylist over detection:* detecting "this domain fronts many merchants" needs
cross-user data the worker does not have. A small explicit list covers the realistic processors, is
auditable, and fails safe — an unlisted aggregator degrades to today's behaviour (duplicates), never
to over-merging (wrongly fused subscriptions). Duplicates are recoverable by the user; a wrongly
merged card silently hides a subscription.

### 3. The bridge is the rollup point, and the DB enforces it — scoped to the pending queue

`bridgeProposalsToCandidates` is the single deterministic choke point every page passes through. The
candidate insert changes from `on conflict (detected_event_id) do nothing` to an upsert on
`(user_id, canonical_merchant_key)` restricted to pending rows, backed by a new partial unique index.

*Why that scope and not `(scan_run_id, …)`:* the scope must match what the user actually sees. The
inbox selects by user and `review_status`, never by run, so a per-run invariant would be enforced
where nobody looks while later scans stacked a second card per merchant — a queue that grows on every
scan. Restricting the index to `review_status = 'pending'` keeps resolved history intact and still
allows a merchant to be proposed again after the user resolves it; whether it *should* reappear is
governed by `merchant_discovery_suppressions`, which is the right place for that judgment.

A merged card takes the newest run's `scan_run_id`, so it stays coherent with the latest scan summary.

*Why the DB and not application logic:* pages run concurrently under the dispatcher. A
read-then-insert in application code is a race with a real interleaving window. A unique index makes
the invariant unconditional, and `on conflict` turns the race into a merge instead of an error.

*Why not fix it only in `propose.ts`:* the in-page `tracked` set cannot see other pages, so it can
never be sufficient. Propagating identity into `propose.ts` is still worthwhile — it stops the agent
spending budget re-proposing within a page — but it is an optimization layered on top of the durable
guarantee, not the guarantee itself.

### 4. Merge semantics: confidence wins, nulls never overwrite

```sql
merchant_name  = case when excluded.confidence > c.confidence then excluded.… else c.… end
amount         = coalesce(<winner>, c.amount, excluded.amount)   -- never null out a known value
confidence     = greatest(c.confidence, excluded.confidence)
```

Highest-confidence evidence supplies the card's identity-bearing fields; a null on the incoming
proposal never erases a value already known. This makes the merge order-independent, which matters
because page completion order is not deterministic.

### 5. Threading sender context to the bridge

`ProposalCandidate.evidence_refs[0]` is already used as the `provider_message_id`, and
`ScanJob.rawMessages` (`MailMetadata[]`, carrying `id` and `sender`) is in scope at the call site in
`page-analysis.ts`. The bridge takes a `messageId -> sender` lookup built from that array — no new
fetch, no schema change on the worker queue.

Identity is resolved at the bridge rather than stored on `ProposalCandidate`, so the agent's typed
proposal contract and its anti-exfiltration bounds are untouched.

## Risks / Trade-offs

- **An unlisted aggregator keeps producing duplicates** → Fails safe by design (decision 2). The
  denylist is a plain constant, cheap to extend when one shows up.
- **A vendor billing from an unrelated domain (e.g. `sendgrid.net`) fragments identity** → Same
  failure as today, no regression. Cross-run suppression still catches it after one user decision.
- **Over-merge if two genuine subscriptions share a direct vendor domain** (e.g. two Google One
  plans) → Real but narrow, and already the behaviour once the user tracks one of them. Accepted:
  the review card is a proposal a human resolves, not a subscription.
- **The unique index cannot be created while duplicates exist** → The migration merges first, then
  indexes, in one transaction (see Migration Plan).
- **Consolidating historical rows could revert a user decision** → Merge keeps the resolved row as
  the survivor; pending duplicates fold into it.
- **`suggested_action` drift on merge** — a card can flip `add` → `review` if a later proposal
  matches a tracked subscription → Recompute from `matched_subscription_id` on merge so the action
  stays consistent with the match.
- **One email evidencing two merchants** (an aggregator receipt listing several subscriptions) makes
  two proposals share a `detected_billing_events` row, and `unique (detected_event_id)` rejects the
  second. That is a constraint *other* than the conflict target, so it raises rather than merging →
  The bridge catches SQLSTATE 23505 and skips that proposal, preserving exactly what the previous
  `on conflict (detected_event_id) do nothing` did. (The underlying inability to record two events
  from one email is pre-existing and out of scope here.)
- **`senderLabel` is not public-suffix aware** — it returns `co` for `vendor.co.uk`, which as an
  identity would fuse every UK vendor → Identity uses a separate `registrableLabel` that understands
  two-part suffixes. `senderLabel` is left alone; it is only a display fallback.

## Migration Plan

One Supabase migration, transactional:

1. Consolidate pending `subscription_candidates` that already collide under
   `(user_id, canonical_merchant_key)`: survivor is the highest-confidence row, non-null fields fold
   in from the losers, the survivor takes the newest run, losers are deleted.
2. `create unique index … (user_id, canonical_merchant_key) where review_status = 'pending'`.

Order matters — the index cannot be built while duplicates exist. Both steps run in one transaction
so a failure leaves the queue untouched. Step 1 is a no-op against current data (no same-key pending
duplicates exist) and is there for safety: a run completing between now and deploy can create one.

**Historical duplicates are not re-keyed.** The observed pairs differ by *key*
(`anthropic` vs `anthropic-claude-pro`), so no key-grouped merge can collapse them — that would need
the identity rules re-derived over old rows. Re-implementing the aggregator and public-suffix logic in
SQL would put a second copy of it where it can drift from the worker's, so the existing cards keep
their old keys and the user resolves them once. New scans are correct from the first run.

Deploy sequence: migration first, then the worker. Version skew is safe — the old worker inserts one
candidate per evidence event, and if the index rejects one, the bridge's unique-violation guard skips
that proposal instead of failing the page. Rollback is dropping the index; merged rows are not
un-merged, which is acceptable because the merged state is the intended state.

## Open Questions

- Should the aggregator denylist be a code constant or configurable via env? Starting as a constant —
  it changes rarely and a code change is reviewable. Revisit if it churns.
- ~~Should `propose.ts` also resolve identity?~~ Resolved: implemented. `validateProposal` takes an
  optional evidence sender, so the in-page `tracked` set keys on identity too.
- Should a merchant the user resolved ever re-enter the queue from a later scan? The partial index
  permits it by design and `merchant_discovery_suppressions` is what actually decides. Worth
  confirming that suppression is written on every "Not one" before relying on it.
