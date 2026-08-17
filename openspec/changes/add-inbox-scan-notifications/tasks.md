## 1. Notification data and security foundations

- [ ] 1.1 Add owner-scoped migrations, indexes, account-deletion cascades, RLS policies, and service-role grants for notification preferences, APNs device installations, Live Activity tokens, outbox events, and delivery attempts.
- [ ] 1.2 Extend authenticated iOS/backend API models to register, refresh, disable, and list the current device installation and Inbox Intelligence outcome preference without exposing another user's tokens or delivery history.
- [ ] 1.3 Add server-only APNs configuration validation and document required Apple capabilities, APNs key/Team/Key/bundle secrets, sandbox/production configuration, and secret rotation.

## 2. Durable inbox scan outcomes

- [ ] 2.1 Implement idempotent scan-batch finalization that derives `review_ready`, `no_new_discoveries`, and authorization-only `reconnect_required` outcomes from terminal jobs and newly created eligible candidates.
- [ ] 2.2 Implement transactional, batch-scoped outbox creation with stable deduplication keys, privacy-minimized route/count payloads, and no raw mailbox/model data.
- [ ] 2.3 Implement a protected scheduled notification-dispatch Edge Function with leases, per-installation idempotency, bounded retries, outcome preference checks, invalid-token cleanup, and delivery audit records.
- [ ] 2.4 Configure the protected scheduler invocation and add operational queries/runbook steps for stuck leases, retry exhaustion, disabled installations, and queued outcomes.

## 3. Native iOS notifications and routing

- [ ] 3.1 Add Push Notifications capability and native notification lifecycle handling for permission-state inspection, contextual consent, APNs registration, token refresh, sign-out cleanup, and authenticated device registration.
- [ ] 3.2 Add a focused Inbox Intelligence alert setting that communicates discoveries, no-results scans, and reconnect alerts without blocking scanning when permission is unavailable.
- [ ] 3.3 Add safe notification and deep-link routing to Inbox Intelligence, including fresh authenticated status fetching and stale/cleared-batch fallback behavior.

## 4. Manual scan Live Activity

- [ ] 4.1 Add a WidgetKit extension and ActivityKit attributes/content state for privacy-minimized inbox scan stage, message count, completed inbox count, optional verified percentage, terminal outcome, and stale state.
- [ ] 4.2 Start and register one Live Activity only for a user-initiated Inbox Intelligence scan on a supported, permitted device; persist and retire ActivityKit push tokens by batch and installation.
- [ ] 4.3 Publish server-driven Live Activity updates only from durable scan progress boundaries, omit percentage where a reliable total is unavailable, and end the activity with the safe terminal outcome.
- [ ] 4.4 Suppress the duplicate ordinary outcome alert on the installation that receives the completed Live Activity while preserving outcome delivery to other enabled devices.

## 5. Verification and rollout

- [ ] 5.1 Add backend tests for batch finalization, concurrent deduplication, no-discovery outcomes, reconnect classification, payload privacy, retry/lease behavior, invalid-token cleanup, and cross-user isolation.
- [ ] 5.2 Add iOS tests for consent denial, token lifecycle, notification routing, Live Activity eligibility, truthful progress formatting, duplicate-alert suppression, accessibility, and Reduce Motion behavior.
- [ ] 5.3 Verify APNs sandbox and production delivery plus Live Activity updates on physical devices, including app backgrounding, offline/stale activity behavior, multiple devices, and daily automatic scans.
- [ ] 5.4 Document the opt-in UX, APNs operational setup, supported terminal outcomes, privacy boundary, and rollback/disable procedure.
