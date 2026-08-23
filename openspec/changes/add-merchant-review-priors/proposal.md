## Why

When a person corrects a discovery suggestion — changing a proposed billing cycle from monthly
to yearly, or fixing a category — that correction is recorded in
`subscription_candidate_review_outcomes` and then never read again. The next time the same
merchant emails, the agent proposes the same wrong values, and the person re-corrects the same
fact every billing period. The feedback loop is already closed for merchant *identity*
(`reviewed_merchant_aliases`) and *suppression* (`merchant_discovery_suppressions`), which are
read back at scan time; field-level corrections are the missing half. Closing this loop makes
the agent measurably more accurate the more a person uses it, without changing what the model
does or removing the human confirmation gate.

## What Changes

- Introduce a per-user store of **learned merchant priors** derived from a person's own confirmed
  and corrected discovery outcomes. Scope of the first cut is deliberately narrow: **billing
  cycle** and **category** only.
- **Write side:** when a person confirms or corrects a candidate, persist a durable prior for
  that merchant when the evidence is confident. Billing-cycle clarification answers persist a
  cycle prior too, instead of only unblocking a single candidate.
- **Read side:** during a scan, after extraction and identity resolution and before a candidate
  or clarification is produced, overlay the person's priors to pre-fill the learned field and to
  suppress a clarification the person has already answered for that merchant.
- Priors are **defaults, not overrides**: they pre-fill values and skip redundant questions, but
  a person still confirms every change, and fresh strong evidence (an explicit price change or
  cancellation) always wins over a stored prior.
- **Out of scope for this change** (parked as follow-ups): learning amount priors, turning
  repeated "ignore" into soft-suppression, cross-user/global priors, few-shotting the model
  prompt, and calibrating confidence thresholds.

## Capabilities

### New Capabilities
- `merchant-review-priors`: A per-user, per-merchant memory of field values (billing cycle,
  category) learned from confirmed and corrected discovery outcomes, written at review time and
  read at scan time to pre-fill candidates and suppress already-answered clarifications, while
  preserving the human confirmation gate and deferring to fresh billing evidence.

### Modified Capabilities
<!-- No synced main specs exist in openspec/specs/; no existing capability requirements change. -->

## Impact

- **New table:** `merchant_review_priors` (per user + canonical merchant key + field), with a
  Supabase migration and RLS scoped to the owning user; no authenticated-client write path beyond
  the Edge Function.
- **`supabase/functions/email-scan/index.ts`:** `recordReviewOutcome` and the clarification
  resolution path gain a prior-write step; `processConnectionJob` gains a prior-read/overlay step
  alongside the existing `reviewed_merchant_aliases` load; `createCandidateFromClarification`
  persists a cycle prior.
- **`supabase/functions/_shared/`:** a new pure module for prior derivation and overlay logic
  (mirrors `inbox-clarification-policy.ts`), with unit tests.
- **No change** to the model prompt, the extraction schema, the DeepSeek call, or the
  human-confirmation requirement. Privacy posture is unchanged: priors store only derived field
  values a person already confirmed, never raw email content.
- Unlocks later confidence calibration (parked Thread C) by making review outcomes joinable to
  the fields they corrected.
