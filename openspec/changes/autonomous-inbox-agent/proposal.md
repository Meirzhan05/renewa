## Why

The inbox-discovery pipeline makes the "is this a subscription?" decision with hand-written
judgment code — keyword lists (`cadence.ts`), a deterministic recurring-vs-one-off verdict, and a
routing ladder of hardcoded thresholds (`0.45` admit, `0.35` min-confidence, `0.25`/`0.1` spread).
Every new merchant, language, or edge case means editing rules. We want the *model* to make every
subscription decision and keep only code that gives the model better eyes (perception) or bounds an
untrusted agent (safety). The human confirmation gate stays: the agent **proposes**, a person
**confirms**.

## What Changes

- **Replace the per-merchant pipeline with a two-tier LLM funnel.** A cheap Tier-1 model reads
  every email's metadata and decides **look / skip** (a decision, not a score + cutoff). Only
  "look" emails reach Tier 2 — a single autonomous agent that groups merchants, judges recurrence,
  dedups, and proposes candidates.
- **BREAKING — delete the deterministic judgment code.** Remove `domain/cadence.ts` (verdict +
  hard override), `domain/routing.ts` (ladder + thresholds), the keyword admit-gate and `0.45`
  threshold in `domain/classifier.ts`, and the per-merchant `select → reason → verify → route`
  walk in `graph/graph.ts`. Emergent grouping replaces `canonicalMerchantKey` bundling.
- **Cadence becomes a *tool*, not a verdict.** Keep the amount/interval/spread math, but expose it
  as `compute_cadence(message_ids)` the agent *may* call — nothing overrides the model.
- **The write is the only side effect, and it is human-gated.** The agent's sole write is
  `propose(candidate)`; proposals are strict-schema, enum/number-typed, length-capped, **no
  free-text notes** (the anti-exfiltration boundary), and a deterministic dedup guard rejects a
  proposal that exact-matches an already-tracked or already-rejected item.
- **Re-scope the tool authorizer for whole-inbox reach.** Reads become read-only over the connected
  account (not per-merchant scope); the safety boundary moves to the `propose` write.
- **Measure recall by sampling skips.** Tier 1 is a hard gate, so periodically route a small random
  sample of *skipped* emails through the agent to estimate the false-negative rate.
- **Cost discipline as a contract:** search-first (lean on the provider index), incremental by
  default (cold full sweep once, then ride push-monitoring), targeted reconcile of existing subs.
- **Single autonomous agent, not sharded** — avoid a supervisor/merge layer; incremental scans are
  cheap and a cold sweep runs fine in the background.
- **Golden-set eval harness becomes a prerequisite**, since emergent search-based triage has no
  other way to prove run-to-run recall is stable.

## Capabilities

### New Capabilities
- `inbox-triage`: Tier-1 cheap-model gate that reads every email's metadata and returns a
  recall-biased look/skip decision, plus the skip-sampling mechanism that measures its recall.
- `autonomous-discovery-agent`: Tier-2 single budgeted, checkpointed agent that reads (search /
  fetch / compute_cadence), reconciles against current subscriptions and prior decisions, performs
  all subscription judgment (grouping, recurrence, completeness, add/ask/drop), and terminates.
- `subscription-proposal-gate`: the human-gated write boundary — `propose` schema and anti-exfil
  constraints, the deterministic dedup/idempotency guard, the confirm/edit/reject flow, and the
  cross-run learning (priors) that feeds the next scan.

### Modified Capabilities
<!-- No specs have been synced to openspec/specs/, so there are no existing capability contracts to
     amend; the deletions above are captured as scope in the new capabilities and in design.md. -->

## Impact

- **Deleted:** `worker/src/domain/cadence.ts`, `worker/src/domain/routing.ts`; the keyword
  admit-gate + threshold in `worker/src/domain/classifier.ts`; the per-merchant node walk and the
  clarify-interrupt branch in `worker/src/graph/graph.ts`; associated tests
  (`cadence.test.ts`, `routing.test.ts`, `clarify-interrupt.test.ts`) are rewritten or removed.
- **Rewritten:** `worker/src/graph/graph.ts` (two-tier funnel), `worker/src/domain/reasoner.ts`
  (single-agent loop + re-scoped authorizer), `worker/src/domain/classifier.ts` → Tier-1
  look/skip triage. New `compute_cadence` tool retains the pure math from `cadence.ts`.
- **New:** golden-set fixture + eval harness; skip-sampling recall probe; `list_current_subscriptions`
  and `list_prior_decisions` read tools; proposal dedup guard.
- **Preserved:** read-only tools (no write/track/send), per-scan budget/termination guarantee,
  sanitize/truncate on fetched bodies, injection-defense prompts, the Postgres checkpointer, and the
  human confirmation gate. Cross-run learning reuses the existing `merchant_review_priors`,
  `reviewed_merchant_aliases`, and `merchant_discovery_suppressions` tables (now consulted by the
  agent, not applied as deterministic overlays).
- **Relationship to `agentic-inbox-discovery`:** this supersedes that change's per-merchant graph
  while keeping its worker/checkpointer foundation and safety invariants.
