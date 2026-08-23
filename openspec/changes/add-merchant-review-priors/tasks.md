## 1. Data model & migration

- [x] 1.1 Add a migration creating `merchant_review_priors` (`user_id`, `canonical_merchant_key`, `field`, `value`, `evidence_strength`, `updated_at`) with a unique constraint on `(user_id, canonical_merchant_key, field)`
- [x] 1.2 Add owner-scoped RLS (select for authenticated is owner-only; writes are service_role via the Edge Function, matching the `reviewed_merchant_aliases` house pattern)
- [x] 1.3 Priors removed on account deletion via `references auth.users(id) on delete cascade` (same mechanism as every other owned table; `delete-account` needs no change)

## 2. Prior policy module (pure, unit-tested)

- [x] 2.1 Create `supabase/functions/_shared/merchant-review-priors.ts` with a write-side function that maps a review outcome (confirmed/corrected fields) to the `billing_cycle`/`category` prior upsert, including evidence-strength increment and conflict-reset-to-latest
- [x] 2.2 Add a read-side overlay function: given an extracted event + loaded priors, return the fields to pre-fill (fill `billing_cycle` only when model value is null; apply `category` prior only when model category is `other`) and whether a billing-cycle clarification should be skipped
- [x] 2.3 Add a helper that recomputes the projected renewal date when a prior sets the billing cycle, reusing the existing `projectedRenewalDate` logic (exported `projectRenewalDate` from `email-discovery.ts`)
- [x] 2.4 Write `merchant-review-priors.test.ts` covering: cycle correction → prior, confirm-without-change → strength increment, conflicting correction → latest value, unsupported field → no prior, "not sure" → no prior, model-concrete value not overwritten, category `other` overlay, no-prior → unchanged behavior

## 3. Write path (review time)

- [x] 3.1 In `recordReviewOutcome`, upsert `billing_cycle`/`category` priors for `confirmed` and `corrected` outcomes via the policy module (shared `learnMerchantPriors` helper)
- [x] 3.2 In the billing-cycle branch of `resolveClarification`, upsert a durable `billing_cycle` prior for concrete answers and record none for `not_sure` (dropped by `derivePriorUpserts`)

## 4. Read path (scan time)

- [x] 4.1 In `processConnectionJob`, load the user's priors once per job alongside subscriptions and `reviewed_merchant_aliases` (built into a `priorsByMerchant` map)
- [x] 4.2 After lifecycle is computed and before clarification drafting / candidate insert, apply the overlay onto a `presentedEvent`: pre-fill fields, recompute renewal date if the cycle was set, and skip an already-answered billing-cycle clarification
- [x] 4.3 Priors never alter `reconcileMerchantLifecycle` inputs (overlay runs after the raw `detected_billing_events` row is saved and after `merchantLifecycle`; only `validation_issues` is re-derived) and `price_changed`/`canceled` handling is unchanged (`event_type` untouched by overlay)

## 5. Verification

- [x] 5.1 `deno check supabase/functions/email-scan/index.ts` passes; 34 shared/discovery tests pass including the `projectRenewalDate` refactor
- [ ] 5.2 Manual check (needs live env): correct a merchant's cycle, re-scan a same-cadence charge, and confirm the candidate arrives pre-filled with no repeat clarification
- [x] 5.3 Confirmation gate structurally intact (no new subscription-write path; candidate stays pending until `reviewCandidate` confirm). RLS + cascade live-verified against local Postgres: an `authenticated` user sees only their own priors (0 of another user's), and deleting an `auth.users` row cascades away exactly that user's priors
- [x] 5.4 Updated `INBOX_AGENT_THREADS.md` to mark Thread A code-complete (manual QA pending) and confirmed Threads B–D remain accurate
