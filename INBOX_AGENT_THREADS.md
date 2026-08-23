# Inbox Discovery Agent — Improvement Threads

Exploration backlog for the AI email-subscription-discovery agent
(`supabase/functions/email-scan/` + `supabase/functions/_shared/email-discovery.ts`).

**How the agent works (one-paragraph recap):** it is *not* an autonomous agent. It's a
constrained pipeline: a keyword prefilter (`candidateSignalScore ≥ 2`) decides which emails
reach the model → the model (`deepseek-chat`, temp 0, JSON) is a pure per-message extractor
that returns `{event | abstain}` and never acts → deterministic TypeScript makes every real
decision (identity resolution, lifecycle reconciliation, action classification) → nothing
changes a subscription without explicit human confirmation. Improvements must preserve that
human-confirmation gate.

Status legend: 🟢 current focus · 🟡 code complete, manual QA pending · ⚪ not started

---

## 🟡 Thread A — Close the feedback loop  *(implemented — change `add-merchant-review-priors`)*

**Problem.** Review decisions are collected but mostly not read back. The loop is already
closed for merchant *identity* (`reviewed_merchant_aliases`, read at `index.ts:643` by
`resolveMerchantIdentity`) and *suppression* (`merchant_discovery_suppressions`), which proves
the pattern. But **field-level corrections are write-only**:
`subscription_candidate_review_outcomes` records `proposed_fields` vs `applied_fields` vs
`correction_reason` (`wrong_amount`, `wrong_cycle`, …) and nothing ever reads it. A user who
corrects Spotify monthly→yearly re-corrects it every month.

**Change.** Add a per-user `merchant_review_priors` table (merchant_key, field, learned value,
evidence strength). Write side: extend `recordReviewOutcome` + clarification handlers to persist
durable priors. Read side: at scan time, after extraction + identity, overlay priors to pre-fill
fields and skip redundant clarifications — mirroring how aliases already work.

**Invariant.** Priors are *defaults, not overrides*: they pre-fill, human still confirms, and
fresh strong evidence (`price_changed`/`canceled`) wins. Per-user only. Does not touch the model
prompt or the confirmation gate.

**Delivered (first cut).** Fields learned: `billing_cycle` + `category` only. New migration
`202608230001_merchant_review_priors.sql`, pure module `_shared/merchant-review-priors.ts`
(+ tests), write hook via shared `learnMerchantPriors`, read overlay in `processConnectionJob`.
Category prior applies only when the model returned the `other` default. Deferred: amount priors,
ignore→soft-suppress, backfill of historical outcomes, strong-category override. RLS + cascade
live-verified against local Postgres (task 5.3). Remaining before ship: the full end-to-end
re-scan pre-fill (5.2), which needs a `DEEPSEEK_API_KEY` and a connected inbox.

---

## ⚪ Thread B — Measure the prefilter's recall (the invisible-miss problem)

**Problem.** `candidateSignalScore ≥ 2` (`email-discovery.ts:153`) decides what the model *ever
sees*. We can measure the precision of what we surface, but we are **structurally blind to
recall**: a billing email that misses the hand-maintained 6-language keyword lists is dropped
and never counted as a miss. Novel merchants, image-only receipts, and unlisted languages are
invisible false negatives.

**Idea.** Periodically route a small random sample of *below-threshold* emails through the model
to estimate the false-negative rate. You can't fix what you can't see; today the miss rate is
unobservable. Longer term, consider a small embedding classifier to replace/augment the keyword
lists so recall generalizes beyond hand-listed terms.

**Watch-outs.** Cost of sampling; sampling must stay privacy-clean (same sanitize/truncate path);
this is measurement first, not a filter rewrite.

---

## ⚪ Thread C — Calibrate the confidence thresholds

**Problem.** Two hardcoded thresholds drive real behavior — `confidence < 0.72` →
`low_model_confidence` (`index.ts` `semanticValidationIssues`), and `>= 0.82` gates whether a
clarification may be asked (`inbox-clarification-policy.ts:22`). These are the **model's
self-reported** confidence at temp 0, which is notoriously uncalibrated. Nobody has verified that
0.72 corresponds to any real accuracy boundary.

**Idea.** Once Thread A joins outcomes back (confirm/ignore/correct per confidence band), compute
the real precision curve and set the thresholds from data instead of a guess. Depends on Thread A.

**Watch-outs.** Need enough labeled outcomes per band before trusting the curve; thresholds may
differ per event_type.

---

## ⚪ Thread D — Identity & lifecycle rigor (where reasoning genuinely helps)

The one place to let the LLM reason *more*, because the problem is genuinely fuzzy and it's
already behind the human gate.

- **D1 — Wire in the dead adjudication path.** `buildMerchantAdjudicationMessages` +
  `validateMerchantAdjudication` (`email-discovery.ts:224-239`) implement an injection-safe
  "are these the same merchant?" model call. **It is never called anywhere.** Today identity is a
  fuzzy key + a hardcoded ~10-brand alias table (`brandIDForMerchant`, `email-discovery.ts:496`);
  ambiguity jumps straight to a human interrupt. Wiring this in reduces user interruptions.
- **D2 — Use cadence as evidence.** `reconcileMerchantLifecycle` only looks at the *latest* paid
  event's projected renewal. Six consecutive monthly charges and one lone charge yield the same
  confidence. Frequency across events is strong signal being discarded.
- **D3 — Sender/merchant cross-check.** `sender_domain` is passed *to the model* but never
  *deterministically* checked against the extracted `merchant_name`. An injection email from
  `evil@spam.com` claiming "Netflix, $99/mo" passes structural validation. The human gate limits
  blast radius to a bad *suggestion*, but a domain↔merchant consistency check is cheap
  defense-in-depth.

---

## ⚪ Extra 1 — Cost & latency

One model call per candidate message (concurrency 3) is the cost driver at high mailbox volume.
Options: batch multiple emails per call (tradeoff: injection blast radius + `message_id`
attribution); **template-fingerprint caching** — a Netflix receipt is byte-identical month to
month, so a content-hash cache of extraction results skips the model for known templates (note:
today dedup happens at *storage* time via `ignoreDuplicates`, i.e. *after* paying for
extraction; no model-result cache exists in the scan path).

## ⚪ Extra 2 — Eval harness / golden set

There is **no labeled fixture set** to regression-test prompt or model changes, yet the model is
swappable via `DEEPSEEK_MODEL` (`index.ts:2823`). Changing model or prompt is currently a leap of
faith. A golden set of sanitized emails → expected `{event|abstain}` may be the true prerequisite
before touching A–D, since it makes every other change verifiable.

---

*Captured during an explore session on 2026-08-23. Threads B–D + extras are parked for after
Thread A ships.*
