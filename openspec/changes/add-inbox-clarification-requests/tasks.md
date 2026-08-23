## 1. Durable clarification data and contracts

- [x] 1.1 Add a migration for owned clarification requests and immutable answer outcomes, including constrained kinds, statuses, deduplication/indexes, expiry, RLS, and service-role access.
- [x] 1.2 Add backend and Swift models for privacy-minimized clarification payloads, bounded answer choices, and resolution results.
- [x] 1.3 Extend the authenticated email-scan status and action contracts to return the highest-priority open clarification and resolve an owned request idempotently.

## 2. Safe scanner and resolution behavior

- [x] 2.1 Implement strict eligibility and prioritization for recent lifecycle, merchant-identity, and billing-cycle ambiguity; exclude weak, stale-only, and marketing evidence.
- [x] 2.2 Deduplicate open questions, expire/supersede them when newer evidence resolves the ambiguity, and prevent immediate re-asking without materially newer evidence.
- [x] 2.3 Resolve clarification answers atomically, recording outcomes and applying only allowed follow-up effects without directly mutating subscriptions.
- [x] 2.4 Create or unblock a normal pending candidate only when a positive answer and existing deterministic validation support it; retain the existing explicit candidate confirmation gate.

## 3. Inbox review experience

- [x] 3.1 Load clarification state through AppStore and refresh Inbox state after a resolution without showing a blocking generic error for a completed answer.
- [x] 3.2 Add one prioritized Quick question card below Inbox status/inbox chips and above handled activity, sharing the existing primary review area with candidate proposals.
- [x] 3.3 Build a focused clarification detail sheet with plain-language rationale, redacted dated evidence, relevant choices, and a Not sure path; keep subscription-edit fields out unless the question concerns that field.
- [x] 3.4 Add accessibility labels, dynamic type-safe layout, explicit no-direct-change copy, and an empty state that remains quiet when no clarification is open.

## 4. Verification and operational documentation

- [x] 4.1 Add backend tests for eligibility, deduplication, supersession, owner isolation, answer retry, Not sure behavior, and the no-direct-mutation invariant.
- [x] 4.2 Add iOS tests for clarification decoding, Inbox prioritization, and safe state transitions after each answer.
- [x] 4.3 Run Deno checks/tests, iOS formatting/lint/build/tests, and migration validation; update Inbox discovery documentation and `todo.md` with the delivered capability and any rollout metrics.
