## 1. Scan dashboard read model

- [x] 1.1 Audit the existing email-scan status, connection, candidate, and evidence payloads against the dashboard specification and document the minimal missing user-scoped summary fields.
- [x] 1.2 Add any required read-only backend/query response for privacy-minimized non-actionable outcome counts and evidence summaries, with ownership checks and no raw mail/model content.
- [x] 1.3 Extend Swift scan presentation models and state mapping to represent no inbox, connecting, scanning, review-ready, completed-no-action, and recoverable-failure states from durable server data.

## 2. Inbox Intelligence dashboard

- [x] 2.1 Replace the static Inbox Intelligence hero with a state-specific scan-health summary showing connection, monitoring, last-run outcome, and only trustworthy run metrics.
- [x] 2.2 Implement durable active-scan presentation with stage and checked-message count, background-continuation guidance, and no fabricated percentage.
- [x] 2.3 Add the primary “Actions for you” section that preserves the existing candidate review flow and gives completed scans with no candidates an explicit no-action state.
- [x] 2.4 Add the secondary privacy-minimized “What we learned” summary, ensuring ended, uncertain, ambiguous, and validation-withheld outcomes are never shown as active subscriptions.
- [x] 2.5 Reorganize connected-inbox controls, notification preference, retry, reconnect, and scan actions as supporting dashboard controls without regressing existing behavior.

## 3. Evidence detail, loading, and accessibility

- [x] 3.1 Add a scan-detail route/sheet for eligible evidence using only merchant label, event type, received date, lifecycle/result reason, and non-verbatim explanation.
- [x] 3.2 Bound skeleton loading to the initial unresolved dashboard request and retain known state during refresh, manual scan, and review actions.
- [x] 3.3 Localize errors to their affected card, suppress expected task-cancellation alerts during tab changes, and provide the relevant retry or reconnect action.
- [x] 3.4 Add accessibility labels, Dynamic Type layout checks, and reduced-motion behavior for dashboard state transitions and evidence details.

## 4. Verification and handoff

- [x] 4.1 Add unit tests for the scan presentation-state matrix, including active scans, no-action completion, review-ready completion, disconnected inboxes, and provider authorization failures.
- [x] 4.2 Add backend tests for any new summary/read-model filtering to verify user ownership and exclusion of raw email/model content.
- [ ] 4.3 Build and run the iOS test suite; manually verify the dashboard in no-inbox, active-scan, completed-no-action, review-ready, and recoverable-error states.
- [x] 4.4 Update `todo.md` and relevant Inbox Intelligence documentation with the dashboard behavior, privacy boundaries, and remaining deployment dependencies.
