## 1. Evidence data model

- [x] 1.1 Add an additive migration for user-owned merchant evidence bundles, bundle-to-event links, reviewed merchant aliases, advisory adjudications, and candidate review outcomes with indexes, RLS, service-role grants, and account-deletion cascades.
- [x] 1.2 Extend discovery candidate/event queries and typed backend records to retrieve only the privacy-minimized evidence fields required for bundle assembly and review.
- [ ] 1.3 Add migration and RLS tests that prove evidence, aliases, adjudications, and review outcomes remain user-isolated and raw mail content is not persisted.

## 2. Deterministic evidence intelligence

- [x] 2.1 Add pure shared types and deterministic merchant identity resolution for canonical keys, reviewed aliases, recognized brands, verified sender-domain evidence, and explicit ambiguity results.
- [x] 2.2 Add pure merchant-bundle assembly and lifecycle eligibility logic that orders resolved events, links supporting evidence, and withholds action for unresolved or ambiguous evidence.
- [x] 2.3 Add a versioned, runtime-validated advisory adjudication schema and bounded request builder that accepts only sanitized event summaries and returns same-merchant, different-merchant, or abstain.
- [x] 2.4 Add resolver, bundle, lifecycle, and adjudication validation tests for aliases, collisions, cancellations, reactivations, abstentions, malformed responses, and adversarial instruction fixtures.

## 3. Scan and review integration

- [x] 3.1 Update the email-scan worker to resolve each extracted event into a bundle before candidate creation, persist supporting-event links, and withdraw stale candidates when bundle lifecycle changes.
- [ ] 3.2 Invoke the advisory adjudicator only for configured ambiguity types, persist its bounded result/version, and ensure invalid or abstaining results cannot create a proposal.
- [x] 3.3 Update candidate confirmation, ignore, suppression, and cancellation flows to persist structured review outcomes and promote only valid, unambiguous reviewed aliases.
- [x] 3.4 Expose evidence summaries, resolution reasons, eligible correction reasons, and review outcomes through authenticated client API responses without exposing raw email data.

## 4. Inbox review experience

- [x] 4.1 Extend Swift models and AppStore state for evidence-backed candidates, resolution explanations, standardized correction reasons, and withheld-ambiguity scan counts.
- [x] 4.2 Add a compact chronological evidence summary and lifecycle/action rationale to actionable candidate review, preserving field editing and explicit confirmation.
- [x] 4.3 Add optional standardized correction-reason selection and alias-correction handling to review/ignore flows, with accessible loading, success, and failure states.
- [x] 4.4 Surface a clear non-actionable scan explanation when discovery withholds ambiguous evidence, without presenting it as a subscription or exposing message bodies.

## 5. Quality measurement and verification

- [ ] 5.1 Add a redacted, synthetic/consented fixture corpus and evaluation runner for extraction validation, identity resolution, bundle lifecycle, and proposal eligibility.
- [ ] 5.2 Record and expose privacy-minimized aggregate telemetry for scan stages, identity/adjudication outcomes, review outcomes, prompt/model versions, latency, and model-cost bands.
- [ ] 5.3 Add backend and iOS tests for evidence display, review-outcome behavior, user isolation, idempotency, suppression, and lifecycle regression cases.
- [ ] 5.4 Update privacy/AI documentation and `todo.md` with retention boundaries, evaluation metrics, and manual validation steps; run OpenSpec validation, Deno tests, Swift formatting, simulator tests, and a device-compatible build.
