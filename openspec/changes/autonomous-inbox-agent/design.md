## Context

The inbox-discovery worker (`worker/`, a LangGraph state machine on a Postgres checkpointer)
currently runs a per-merchant pipeline: an LLM classifier admits mail, then each merchant walks
`select → reason ⇄ tools → verify → route`. Three of five stages are already LLM calls, but the
decisions that actually classify a subscription are hand-written: `domain/cadence.ts` (keyword lists
+ a deterministic recurring-vs-one-off verdict that overrides the model), `domain/routing.ts` (a
ladder gated on `0.35` min-confidence), and the `0.45` admit threshold in `domain/classifier.ts`.
Adding a merchant, language, or edge case means editing rules.

We want the model to make every subscription decision. Deterministic code is kept only when it
(a) gives the model better eyes — *perception* (amount parsing, interval math, sanitization) — or
(b) bounds an untrusted agent — *safety* (tool authorizer, budget/termination, the human gate).
The `worker/` foundation, its safety invariants, and the human confirmation gate all stay. Notably,
the original worker was justified by *durable mid-run clarification*; in this design a proposal *is*
the question, so clarification collapses into the write and cross-run learning — the worker now
earns its keep as an untimed long tool-loop, not as a run that spans a pause.

## Goals / Non-Goals

**Goals:**
- Two-tier LLM funnel: a cheap Tier-1 model decides `look`/`skip` for every email; a single
  autonomous Tier-2 agent does all judgment on what passes.
- Delete the deterministic judgment code (`cadence.ts` verdict, `routing.ts`, keyword admit-gate and
  thresholds, the per-merchant node walk).
- Preserve the human-proposes gate, read-only tool safety, budget/termination, sanitization, and
  injection defense.
- Make recall observable (skip-sampling) and regression-safe (golden-set eval) despite emergent,
  non-deterministic triage.

**Non-Goals:**
- Removing the human confirmation gate. The agent proposes; a person confirms. (Explicitly chosen.)
- Auto-committing subscriptions.
- Sharded/multi-agent parallelism — out of scope; a single agent is enough given incremental scans.
- Replacing the mail provider's search index with a local classifier or embeddings (possible later;
  not required here).

## Decisions

### D1 — Two-tier funnel with a look/skip *decision*, not a score + cutoff
Tier 1 reads every email's metadata and returns a discrete `look`/`skip`, recall-biased ("when in
doubt, look"). *Alternatives:* keep today's confidence score + `0.45` cutoff (rejected — the cutoff
is exactly the hand-tuned filtering we're removing); pure search-only triage with no wide pass
(rejected — recall would depend entirely on the agent guessing query terms, the same blind spot as
keyword code, just relocated). The wide pass is *perception* (a model sees every email), not a
*gate that decides for the model*.

### D2 — Cadence is a tool, not a verdict
Keep the amount/interval/spread math from `cadence.ts` but expose it as `compute_cadence(ids)` the
agent *may* call; delete `classifyRecurrence`/`reconcileRecurrence` and their hard override.
*Rationale:* the repo has a regression test proving the pure-LLM version mistook Uber rides for a
subscription — but it was deciding *blind*. Giving the model the cadence features as evidence keeps
it fully in charge without repeating that failure. *Alternative:* trust raw fetched bodies with no
cadence tool (rejected — needlessly re-opens the documented precision failure).

### D3 — Whole-inbox read scope; safety boundary moves to the write
Per-merchant scope disappears, so the authorizer is re-scoped: reads are read-only over the connected
account. The new blast-radius concern is `propose` as an exfiltration channel, so the hard wall is
the proposal schema — typed, bounded, **no free-text notes**. *Alternative:* keep tight per-merchant
read scope (rejected — incompatible with emergent grouping and whole-inbox reconciliation).

### D4 — Deterministic dedup guard on `propose`
Emergent grouping means "already tracked / already rejected" is no longer a hard join, so the agent
must consult `list_prior_decisions` — a *soft* honoring. A thin deterministic guard on the `propose`
write rejects exact-match duplicates as a backstop. *Rationale:* re-proposing a killed candidate is
the fastest way an AI feature feels broken; this guard filters *duplicate proposals*, not
*subscriptions*, so it is idempotency plumbing, not judgment. *Alternative:* trust the agent fully
(rejected — too fragile for a user-facing annoyance).

### D5 — Single agent, not sharded
One sequential agent per scan. *Rationale:* incremental scans are tiny; a cold sweep at ~1–3 min in
the background is fine. Sharding buys speed but re-introduces a supervisor + cross-agent merge/dedup
layer — the orchestration we're deleting. *Alternative:* supervisor + parallel workers (rejected for
now; revisit only if cold-sweep latency becomes a real complaint).

### D6 — Cost discipline as contract
Search-first (lean on the provider index; never ingest all mail into context), fetch sparingly
(fetch is 10–15× a metadata row and is separately budget-capped), incremental by default (cold sweep
once, then ride the existing push-monitoring window), targeted reconcile of existing subs by
per-sub search. Order-of-magnitude on DeepSeek: cold sweep ≈ $0.15–0.50 one-time; incremental
< $0.02.

### D7 — Golden-set eval is a prerequisite, not a follow-up
Emergent search-based triage has no other way to prove run-to-run recall is stable, so a labeled
fixture set (sanitized emails → expected proposals/abstains) lands with the change, and skip-sampling
provides ongoing false-negative measurement in production.

## Risks / Trade-offs

- **Tier-1 is a hard gate; a `skip` is a silent permanent drop → recall ceiling.** Mitigation:
  recall-biased prompt (D1) + skip-sampling probe measures the miss rate + golden-set catches
  regressions (D7).
- **Non-deterministic emergent grouping → unstable/duplicate proposals across runs.** Mitigation:
  reconcile tools (`list_current_subscriptions`, `list_prior_decisions`) + deterministic dedup guard
  (D4) + golden-set assertions.
- **Whole-inbox reads widen injection blast radius.** Mitigation: reads are low-harm read-only; the
  real channel (`propose`) is schema-locked with no free text (D3); injection-defense prompts and
  sanitize/truncate retained.
- **Eager fetching is the one real cost bomb.** Mitigation: a dedicated fetch budget cap enforced by
  the authorizer, independent of the overall token budget (D6).
- **Budget cap is also the recall cap (same dial, opposite pulls).** Mitigation: make it tunable per
  user tier rather than a single hardcoded value; measure recall (D7) to set it from data.
- **Large deletion surface (`cadence.ts`, `routing.ts`, per-merchant walk, clarify-interrupt).**
  Mitigation: land behind the eval harness first so behavior change is measured, not guessed; keep
  the worker/checkpointer/tool foundation intact to bound the blast radius of the rewrite.

## Migration Plan

1. Build the golden-set fixture + eval harness against the *current* pipeline to establish a baseline.
2. Add Tier-2 read tools (`list_current_subscriptions`, `list_prior_decisions`, `compute_cadence`)
   and the re-scoped authorizer without removing the old path.
3. Add the `propose` write with schema validation + dedup guard, mapping to the existing
   proposal/clarification queue and the learning tables.
4. Introduce Tier-1 look/skip triage alongside the old classifier; compare on the golden set.
5. Cut the graph over to the two-tier funnel; delete `cadence.ts`, `routing.ts`, the keyword
   admit-gate/threshold, the per-merchant node walk, and the clarify-interrupt branch (and their
   tests) once the eval baseline is met or beaten.
6. Enable skip-sampling in production and watch the false-negative estimate before widening budgets.

**Rollback:** the old per-merchant graph stays in history and can be re-enabled by config until step
5's deletion; keep the cutover behind a flag until eval + skip-sampling look healthy.

## Open Questions

- **Keyword fallback:** keep `isLikelyBillingCandidate` purely as a Tier-1-offline availability
  fallback, or delete it and treat a triage outage as a retryable error? (Spec requires only "no
  silent loss.")
- **Merchant hint from Tier 1:** should Tier 1 emit a cheap best-guess merchant string to help the
  agent group, at a small added cost, or stay strictly look/skip?
- **Budget defaults:** what per-scan fetch/token/wall-clock caps balance recall against cost for the
  cold sweep vs. incremental runs, and should they differ by user tier?
- **Reconcile depth:** how aggressively should the agent search per existing subscription for
  cancellations/price changes each run before it costs more than it's worth?
