## 1. Monitoring State and Secure Work Queue

- [x] 1.1 Add owner-scoped monitoring-watch state for each email connection, including provider resource identifiers, expiry, health, safe error details, last event, and renewal timestamps.
- [x] 1.2 Add durable event-receipt and connection-due-work tables with RLS, service-role-only mutations, deduplication keys, debounce timestamps, and job-claim indexes.
- [x] 1.3 Extend the inbox status read model and Swift decoders with monitoring health, last successful automatic check, fallback status, and safe recovery reason.
- [ ] 1.4 Add migrations and backend tests that verify cross-user isolation, duplicate event safety, disconnect cleanup, and no exposure of credentials or raw message data.

## 2. Provider Monitoring Adapters

- [x] 2.1 Add a provider-neutral monitoring coordinator and Google adapter that provisions, renews, and removes Gmail watches using server-only configuration.
- [x] 2.2 Add a Microsoft adapter that provisions, validates, renews, and removes Graph mail subscriptions using per-connection verification state.
- [x] 2.3 Extend OAuth completion and inbox disconnect flows to provision monitoring only after a successful connection and to remove provider monitoring on disconnect.
- [x] 2.4 Add bounded renewal processing with retry/backoff, explicit authorization-failure handling, and monitoring-health transitions.
- [x] 2.5 Add unit tests for provider-watch request construction, expiry/renewal decisions, invalid authorization, and cleanup behavior.

## 3. Verified Event Intake and Incremental Work

- [x] 3.1 Add a Gmail Pub/Sub event endpoint that validates configured delivery identity, decodes mailbox/history signals safely, deduplicates receipts, and never trusts event payloads as complete mailbox state.
- [x] 3.2 Add a Microsoft Graph webhook endpoint that completes validation-token handshakes, verifies client state for notifications, deduplicates receipts, and safely rejects unknown resources.
- [x] 3.3 Implement per-connection debounce and due-work claiming so event bursts create one incremental scan and events during a scan retain a follow-up check.
- [x] 3.4 Integrate due work with the existing durable `email-scan` jobs, Gmail history cursor, Microsoft delta cursor, and terminal notification publication without changing review-first candidate policy.
- [ ] 3.5 Add integration-style backend tests for duplicate events, active-scan follow-up, missed-event cursor recovery, invalid webhook input, and zero-candidate automatic completion.
- [x] 3.6 Bound initial historical discovery to 180 days, use a 90-day provider-cursor recovery window, and verify both provider request policies.

## 4. Reconciliation, Operations, and Deployment

- [x] 4.1 Separate protected scheduled commands for watch renewal and daily cursor reconciliation, with bounded batch processing and safe operational logging.
- [x] 4.2 Update Supabase configuration and runbooks with the required Google Pub/Sub topic/identity, Microsoft Graph callback and subscription settings, server secrets, cron/pg_net calls, and manual verification steps.
- [ ] 4.3 Configure and verify the hosted provider infrastructure and Supabase secrets in a non-production environment before enabling automatic provisioning for user connections.
- [x] 4.4 Add monitoring-health metrics or auditable status for received events, deduped events, queued scans, renewal failures, fallback scans, and reconnect-required connections.

## 5. Proactive Inbox Intelligence Experience

- [x] 5.1 Update `EmailDiscoveryPresentationState` and dashboard state mapping to distinguish active event monitoring, reconciling, degraded-with-fallback, and reconnect-required inboxes.
- [x] 5.2 Reframe Inbox Intelligence copy and hierarchy around automatic monitoring, privacy-minimized “last checked” state, and truthful degraded-state guidance.
- [x] 5.3 Replace the primary manual scan framing with an optional secondary “Check now” control while preserving accessible scan progress and recovery feedback.
- [x] 5.4 Ensure automatic scans do not generate per-email progress notifications and continue to use the consented terminal outcome policy only.
- [x] 5.5 Add Swift tests for monitoring state presentation, degraded/reconnect wording, and manual-check availability.

## 6. Verification and Rollout

- [x] 6.1 Run TypeScript checks and backend tests for the event, renewal, queue, cursor, and notification paths.
- [ ] 6.2 Run the iOS build and XCTest suite, then manually verify healthy monitoring, active background scan, no-candidate completion, review-ready, degraded, and reconnect-required dashboard states.
- [ ] 6.3 Perform a staged rollout with provider event delivery enabled for a test cohort, verify daily reconciliation catches missed events, and document the rollback procedure.
