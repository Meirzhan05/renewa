## 1. Lifecycle data foundation

- [ ] 1.1 Add forward-only schema for provider source timestamps, candidate system resolution, and user-owned merchant discovery suppressions with RLS, grants, indexes, and safe backfill.
- [ ] 1.2 Add pure lifecycle reducer helpers for ordering merchant-local events, projected renewals, conservative current/ended/uncertain outcomes, and explainable resolution reasons.
- [ ] 1.3 Add backend tests covering receipt/cancellation ordering, annual renewals, trials, stale dates, conflicts, late events, and suppression behavior.

## 2. Lifecycle-aware discovery service

- [ ] 2.1 Persist source-received time for extracted Gmail and Microsoft events and load merchant-local evidence after each valid event.
- [ ] 2.2 Reconcile lifecycle before candidate creation, resolve stale pending candidates, and preserve review-required matched cancellation proposals.
- [ ] 2.3 Recheck lifecycle before confirmation so superseded proposals cannot mutate subscriptions.
- [ ] 2.4 Add authenticated suppress and unsuppress operations with ownership checks and candidate queue updates.
- [ ] 2.5 Align status responses and non-sensitive telemetry with lifecycle outcomes and the Inbox-focused incremental coverage boundary.

## 3. iOS review experience

- [ ] 3.1 Extend discovery models and API operations for lifecycle/system-resolution data and merchant suppression.
- [ ] 3.2 Add “I don’t use this” to eligible review cards with clear non-cancellation copy and recovery messaging.
- [ ] 3.3 Update empty, progress, and privacy copy to distinguish current review items from historical/uncertain evidence and best-effort Inbox scanning.
- [ ] 3.4 Add XCTest coverage for lifecycle-aware candidate presentation and suppression eligibility.

## 4. Quality and delivery

- [ ] 4.1 Update README and setup documentation with lifecycle decision boundaries and incremental-mail coverage.
- [ ] 4.2 Update `todo.md`, run backend formatting/lint/type/tests, XCTest, simulator/device builds, migration checks, and OpenSpec validation.
