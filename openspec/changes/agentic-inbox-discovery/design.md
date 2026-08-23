## Context

Today's discovery pipeline (`supabase/functions/email-scan/index.ts` +
`_shared/email-discovery.ts`) is **message-centric**:

```
fetch → keyword prefilter (score ≥ 2) → per-message LLM extract (one event, "never infer")
      → validate → per-merchant reconcile (AND-gated isPaidRecurringEvent) → present only "current"
```

It is tuned hard for precision/safety: no invented amounts, no autonomous action, a human
confirms every add, and email content is untrusted. Its failures are on the **recall**
axis. The anchor bug: an Anthropic receipt carrying amount + currency but no literal
"monthly" is stored in `detected_billing_events`, then discarded at reconciliation because
`isPaidRecurringEvent` requires `billing_cycle !== null` (`email-discovery.ts:658`); because
extraction is per-message, no sibling email (the welcome email, a renewal reminder) can
supply the cycle. The computed `abstainReason` is then thrown away (`index.ts:680`).

Constraints that shape this design:
- Runs inside Supabase edge functions with wall-clock/CPU limits and an existing
  run/continuation model (`maximumMessagesPerHistoricalPage`, incremental caps, page tokens).
- One provider call already exists (DeepSeek, OpenAI-compatible). Adding a second model is a
  config + secret change, not new infra.
- The human-confirmation gate and untrusted-data discipline are non-negotiable invariants.

## Goals / Non-Goals

**Goals:**
- Reason per **merchant**, not per **email**, so split evidence combines.
- Make the discovery step **agentic**: a bounded loop that can actively gather more evidence
  (`search_inbox` / `fetch` / `get_more`) before concluding.
- Turn "missing one field" into **one clarification**, not a silent drop (confidence ladder).
- Add a two-tier model split: a cheap/fast tier-1 classifier for wide recall, DeepSeek tier-2
  for per-merchant reasoning + verification.
- Keep precision while relaxing "never infer" via an **extract→verify** grounding pass.
- Preserve every safety invariant and make failures **visible** (persist near-misses).

**Non-Goals:**
- Cross-scan evidence ledger (accumulate across scans) — follow-up change.
- Golden-set evaluation harness — follow-up change (but see Risks: we ship basic metrics).
- Any change to the human-confirmation UX contract or auto-tracking. Nothing auto-adds.
- Replacing the deterministic `reconcileMerchantLifecycle` state machine — it stays.

## Decisions

### D1. Reasoning unit: merchant bundle, not message

Group admitted messages by resolved merchant and reason over the bundle. Rationale: the
whole class of "basic mistakes" comes from judging emails in isolation. Bundling lets a
receipt borrow the cycle from a renewal reminder, and lets "account created + money paid"
combine into "active subscription" even with no single conclusive email.

_Alternative considered:_ keep per-message extraction, add only a smarter reconcile. Rejected
as the primary design because it can only recombine what each isolated extraction already
emitted; it cannot go **find** the missing email. It survives as the fallback path (see D6).

### D2. Two-tier models

- **Tier-1 (wide classifier):** a cheap/fast model behind OpenAI-compatible config
  (`CLASSIFIER_BASE_URL` / `CLASSIFIER_API_KEY` / `CLASSIFIER_MODEL`). Runs over metadata +
  snippet of **all** fetched messages → `{relevant, confidence, merchant_guess, rank}`.
  Replaces `isLikelyBillingCandidate` as the recall gate; keyword score becomes a fallback.
- **Tier-2 (reasoner + verifier):** existing DeepSeek endpoint, rich per-merchant prompt.

Rationale: recall gate wants breadth + low cost per item; reasoning wants depth. Splitting
lets each be right-sized, and moves the expensive call from once-per-email to
once-per-merchant. _Alternative:_ both tiers on DeepSeek (simpler, no new secret) — kept as a
config fallback if `CLASSIFIER_*` is unset, but the chosen default is a separate cheap model.

### D3. The agentic loop and its tool surface

Per merchant, DeepSeek runs a tool-use loop:

```
state = bundle(merchant)                         # classifier-tagged messages
repeat while budget remains:
    assess(state) → {existence, completeness, missing[], fields, confidence, done?}
    if done or confident: break
    choose one tool:
        search_inbox(query)   # metadata search within THIS connection
        fetch(message_id)     # full sanitized body, IDs surfaced this scan only
        get_more(sender)      # more messages from a merchant-associated sender
    state += observe(tool)
emit assessment
```

Tools are **read-only** and **scoped**: `search_inbox` cannot leave the current connection;
`get_more(sender)` is restricted to sender domains tied to the merchant; `fetch` is
restricted to message IDs surfaced within the scan. Every tool argument is validated against
these scopes server-side before execution (the model proposes, the orchestrator authorizes).
There is deliberately **no** tool that writes, tracks, or sends outward.

_Alternative considered:_ bundle-only re-reason with no live fetch (safer, cheaper). Rejected
per product intent — the point of the app is an agent that goes and looks — but its guarantees
are recovered by D4/D5.

### D4. Hard budget envelope (the price of "full live agent")

Because the loop is autonomous over untrusted data, safety comes from **bounded blast
radius**, not from trusting the model:

| Budget | Scope | Purpose |
|---|---|---|
| `maxIterations` (~3–4) | per merchant | terminate the loop |
| `maxToolCalls`, `maxFetches` | per merchant | bound cost/latency |
| `maxTokens`, wall-clock timeout | per merchant | fit edge-function limits |
| `maxMerchantsPerRun` | per run | bound total work; overflow → continuation |
| global token/cost budget | per run | hard ceiling for the scan |

On any budget exhaustion the loop emits a **best-effort, reduced-confidence** assessment
(never a hang, never an auto-present). Overflow merchants defer to the existing continuation
mechanism rather than blowing the run budget.

### D5. Extract→verify grounding pass

After the loop, a cheap tier-2 verification call checks each asserted field against the
evidence paraphrase; ungrounded fields are stripped and an ungrounded existence claim is
downgraded to low-existence. Rationale: this is what lets us relax "never infer" (needed to
default a cycle-less receipt into "ask") without importing hallucination risk. Amounts remain
never-inferred regardless.

### D6. Confidence-ladder routing (the Anthropic fix)

Route on two axes into the **existing** surfaces:

```
                 complete                     incomplete
 high existence  → PRESENT candidate          → ASK one clarification (billing_cycle_check)
 low  existence  → (rare) present w/ note      → WATCH / near-miss (persist, no prompt)
```

The verified assessment feeds the unchanged `reconcileMerchantLifecycle`; "high existence,
missing cycle" now maps to a clarification instead of `uncertain`. Once the user answers, the
existing `merchant_review_priors` write-back pre-fills the cycle on the next scan — this
change composes with the priors feature already shipped.

### D7. Persistence

New storage for near-misses / abstain reasons (`merchant, existence, completeness,
missing_fields, reason, run_id`) and per-run agent-budget accounting (tool calls, tokens,
merchants processed). Migration only; no change to `subscriptions` or the confirmation
contract. Data is RLS-scoped per user and `on delete cascade`, consistent with existing
tables.

## Risks / Trade-offs

- **Prompt injection into an autonomous loop** → Read-only, connection/merchant-scoped tools
  with server-side argument validation; hard budgets; unchanged human gate. Worst case is
  wasted budget or a proposal a human rejects — never state mutation or out-of-scope reads.
- **Cost/latency blow-up on large inboxes** → per-merchant + per-run budgets, merchant cap,
  and continuation; move expensive calls to once-per-merchant; tier-1 stays metadata-only.
- **Relaxing "never infer" hurts precision** → the D5 verifier is a hard precondition; amounts
  stay never-inferred; the ladder routes uncertainty to a *question*, not an auto-add.
- **Edge-function time limits vs. a multi-step loop** → tight per-merchant wall-clock caps,
  bounded concurrency, and merchant overflow to continuation; a single scan never depends on
  finishing every merchant in one invocation.
- **New model dependency / secret** → OpenAI-compatible config with fallback to DeepSeek (and
  ultimately to the keyword gate) so a missing/broken `CLASSIFIER_*` degrades, not breaks.
- **"Better" is unmeasured** → ship lightweight per-run counters (candidate/present/ask/
  near-miss/abstain, tool calls, cost) now; the full golden-set harness is the next change.
- **Nondeterminism from a loop** → temp 0 where supported, strict output schema + validation,
  and idempotent upserts keyed as today so re-runs converge.

## Migration Plan

1. Ship behind a scan-time feature flag / env switch; classifier and loop default off until
   `CLASSIFIER_*` and the flag are set, so deploying is inert without configuration.
2. Add migration for near-miss/budget tables.
3. Roll out tier-1 classifier first (recall gate) with keyword fallback; verify scans still
   complete and candidate counts look sane.
4. Enable the per-merchant reasoner + verifier + ladder for the current user's own inbox
   (dogfood), watching the per-run counters and cost.
5. Rollback: flip the flag off → pipeline reverts to keyword prefilter + per-message extract;
   new tables are inert. No data migration to undo.

## Open Questions

- Which concrete tier-1 model to default `CLASSIFIER_MODEL` to (kept vendor-neutral in this
  change; decided at deploy time).
- Exact budget constants (`maxIterations`, `maxMerchantsPerRun`, global cost ceiling) — start
  conservative, tune against the per-run counters once dogfooding.
- Whether near-misses should surface in the iOS app now or stay backend-only until the eval
  harness follow-up (proposal treats app surfacing as optional).
