## 1. Renewal-date projection (D1)

- [x] 1.1 Locate the existing renewal projection used for `projected_current_renewal` in
  `email-scan/index.ts` / `_shared/email-discovery.ts`; if none is reusable, add a small pure
  helper `projectRenewalDate(baseISODate, cycle)` that adds one weekly/monthly/quarterly/yearly step.
  → DONE: reuse the already-exported `projectRenewalDate(cycle, fromISODate)` in
  `_shared/email-discovery.ts:684` (base precedence `event_date ?? source_received_at`, per
  `projectedRenewalDate`). No new helper needed.
- [x] 1.2 In `createCandidateFromClarification`, when `billingCycle` is known and
  `event.renewal_date` is null, set the candidate's `renewal_date` to
  `projectRenewalDate(billingCycle, event.event_date ?? event.source_received_at)`; keep an
  existing `renewal_date` untouched. (Added `event_date,source_received_at` to the SELECT; new
  `isoDatePart` helper for base-date precedence.)
- [x] 1.3 Unit-test the projection helper (each cycle; month-end clamp; invalid base → null) —
  `_shared/renewal-projection.test.ts`, 3 tests passing.

## 2. Treat the clarified event as human-confirmed (D2)

- [x] 2.1 In the clarified path, after computing `semanticValidationIssues`, drop
  `low_model_confidence` and `missing_renewal_date` from the issue list (via `CLARIFIED_SOFT_ISSUES`).
  Keep `missing_amount` / `missing_currency` (and merchant_match_required / reactivation) as hard blockers.
- [x] 2.2 `amount` + `currency` presence still required (early return `missing_price_or_cycle`); the
  displayed `confidence` value is not mutated (honesty preserved).

## 3. Conditional resolution — no silent consumption (D3)

- [x] 3.1 `createCandidateFromClarification` now returns `{ created: boolean; reason?: string }`;
  reasons set on each early return (`not_applicable`, `event_not_found`, `missing_price_or_cycle`,
  the blocking-issue list, `candidate_not_persisted`).
- [x] 3.2 After the upsert, selects the candidate by `detected_event_id`; `created` reflects whether
  a row exists (idempotent duplicate correctly reports `created: true`).
- [x] 3.3 Resolve flow branches on the return: `created` → `candidate_unblocked`; actionable but not
  created → `answered_no_candidate` (new effect value, migration
  `202608240001_clarification_effect_answered_no_candidate.sql`); still resolves, never mislabeled.
- [x] 3.4 `console.warn` logs the `answered_no_candidate` branch with the request id, answer, and reason.

## 4. Verify end-to-end

- [x] 4.1 `deno check` clean (index + all `_shared`); `deno test _shared/` → 54 passed, 0 failed.
- [ ] 4.2 Manual/dogfood (after deploy + db push): answer the Anthropic "How often…?" clarification
  → candidate appears in "Needs your review" with a "Track it" / "Not mine" choice and a projected
  renewal date.
- [ ] 4.3 Manual/dogfood: confirm a genuinely un-actionable answer records `answered_no_candidate`
  (with reason in logs) and does not silently vanish as `candidate_unblocked`.
