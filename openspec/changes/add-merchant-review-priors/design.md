## Context

The inbox discovery agent already closes a feedback loop for two kinds of review signal:
identity corrections become `reviewed_merchant_aliases` and unused-merchant decisions become
`merchant_discovery_suppressions`. Both are written at review time and read back at scan time
inside `processConnectionJob` (the aliases load at `index.ts:643`, feeding
`resolveMerchantIdentity`). Field-level corrections follow no such loop:
`recordReviewOutcome` writes `proposed_fields` vs `applied_fields` vs `correction_reason`
(`wrong_cycle`, `wrong_amount`, …) into `subscription_candidate_review_outcomes`, and nothing
ever reads that table. As a result a person re-corrects the same merchant's billing cycle every
period.

This change adds the missing loop for two low-risk fields (`billing_cycle`, `category`) by
following the pattern the codebase already proves works for aliases. The model, its prompt, the
extraction schema, and the human-confirmation gate are untouched.

## Goals / Non-Goals

**Goals:**
- Persist a per-user, per-merchant prior for `billing_cycle` and `category` from a person's own
  confirmed/corrected outcomes and from concrete billing-cycle clarification answers.
- Read priors at scan time to pre-fill fields the model left undetermined and to skip a
  clarification the person already answered.
- Keep priors as defaults: model-provided concrete values and fresh lifecycle evidence always win;
  a human still confirms every change.
- Reuse existing structure — a pure `_shared` module with unit tests, mirroring
  `inbox-clarification-policy.ts`, and a load/overlay step mirroring the aliases load.

**Non-Goals:**
- Learning amount priors, soft-suppressing repeatedly-ignored merchants, cross-user/global priors,
  few-shotting the model prompt, or calibrating confidence thresholds. These are parked follow-ups
  (see `INBOX_AGENT_THREADS.md`).
- Any change to model behavior, the extraction schema, or the confirmation requirement.

## Decisions

**1. Row-per-field table over a per-merchant JSON blob.**
`merchant_review_priors(user_id, canonical_merchant_key, field, value, evidence_strength,
updated_at)`, unique on `(user_id, canonical_merchant_key, field)`. Rationale: matches the shape
of `reviewed_merchant_aliases`/`merchant_discovery_suppressions`, keeps RLS trivial, and lets the
read path load only the fields it cares about. Alternative — a JSON priors column on a merchant
row — was rejected: harder to evolve per-field and to reason about in RLS.

**2. Derivation and overlay live in a pure `_shared` module.**
A new `merchant-review-priors.ts` exports the write-side derivation (given a review outcome, what
prior to upsert) and the read-side overlay (given an extracted event + loaded priors, what to
pre-fill and which clarification to skip). Rationale: `index.ts` is ~2900 lines; the clarification
policy already demonstrates that pure, unit-tested policy modules are the house style. Alternative
— inline logic in `index.ts` — was rejected as untestable.

**3. Priors fill gaps; the model's concrete value wins — with a category carve-out.**
`billing_cycle` is nullable from the model, so a prior applies exactly when the model left it null.
`category`, however, is a required enum the model *always* returns, defaulting toward the
low-information `other`. To make a category prior useful without overriding confident
categorizations, a category prior applies only when the model returned `other`; any specific model
category wins. Rationale: preserves "fresh model evidence wins" while still learning the ambiguous
default case. Alternative — always override category with a strong prior — is noted as an open
question, not adopted in the first cut.

**4. Apply after one confident correction; conflicts take the latest value.**
Evidence strength is a count of consistent supporting outcomes. A prior is eligible to apply at
strength ≥ 1 for these two low-risk fields; a conflicting later outcome overwrites the value and
resets strength to 1. Rationale: cycle/category are low blast-radius and a human still confirms, so
requiring two consistent corrections would just make people re-correct twice. The stricter "≥ 2 to
apply" bar is reserved for higher-risk signals in later threads.

**5. Write hooks piggyback on existing review paths.**
`recordReviewOutcome` gains a prior-upsert for confirmed/corrected outcomes; the billing-cycle
branch of `resolveClarification`/`createCandidateFromClarification` upserts a cycle prior.
Read hook: `processConnectionJob` loads priors for the user once per job (alongside subscriptions
and aliases) and the overlay runs after `resolveMerchantIdentity`, before clarification drafting
and candidate insert.

**6. Confirmation gate and lifecycle logic are structurally untouched.**
Priors only ever set `billing_cycle`/`category` on a *proposed* candidate. They never write to
`subscriptions`, never change `reconcileMerchantLifecycle`, and never fabricate an event. A
pre-filled candidate flows through the same `semanticValidationIssues` and confirmation path as any
other.

## Risks / Trade-offs

- **A stale cycle prior masks a genuine plan change (monthly → yearly upgrade).** → The model's
  concrete extracted cycle always wins over the prior; a prior only fills a null. A real event that
  states a different cycle overwrites the prior. Blast radius is a wrong *default* on a card the
  person still confirms.
- **Over-suppressing clarifications hides real ambiguity.** → A prior suppresses only the exact
  field it covers (e.g. a cycle prior silences only the billing-cycle question); identity and
  lifecycle clarifications are unaffected, and conflicting fresh evidence still surfaces.
- **A wrong first correction poisons later scans.** → Human confirmation on every candidate bounds
  the impact; the latest correction supersedes; strength resets on conflict.
- **Applying a cycle prior must keep the projected renewal date coherent.** → When a prior sets the
  cycle, the candidate's renewal projection must be recomputed with the same
  `projectedRenewalDate` logic the pipeline already uses, not left at a value computed for a
  different cadence.
- **Category default carve-out could feel surprising.** → Limited to the `other` case where the
  model expressed no real signal; documented and covered by a scenario.

## Migration Plan

1. Additive migration: create `merchant_review_priors` with the unique constraint, owner-scoped
   RLS (select/insert/update/delete restricted to `auth.uid() = user_id`), and inclusion in the
   account-deletion cascade (`delete-account` function + any cascade FK).
2. Deploy the migration, then deploy `email-scan` with the write and read hooks behind the new
   `_shared` module.
3. Forward-only learning by default (priors accrue from new reviews). A one-time backfill from
   existing `subscription_candidate_review_outcomes` is optional and treated as an open question.
4. Rollback: the read overlay is additive and null-safe; disabling it reverts behavior to the
   current pipeline with the table left in place (no destructive rollback needed).

## Open Questions

- **Backfill?** Derive initial priors from historical `subscription_candidate_review_outcomes` on
  first deploy, or learn forward-only? (Leaning forward-only for a clean first cut.)
- **Strong category override?** Should a category prior at strength ≥ 2 override a specific
  (non-`other`) model category, or is the `other`-only rule sufficient long term?
- **Renewal recompute ownership:** confirm the exact call site where a prior-set cycle triggers
  renewal-date recomputation so the candidate stays internally consistent.
