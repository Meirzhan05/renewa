## Why

Inbox Intelligence presents a manual scanner even though a connected inbox should protect a person continuously. The current daily incremental monitor is a useful fallback, but it cannot reliably react when a new billing email arrives and its hosted schedule may not be configured.

## What Changes

- Add provider-event-driven monitoring for connected Gmail and Microsoft inboxes so new mailbox activity schedules an incremental scan without opening Renewa.
- Keep the existing cursor-based scan pipeline, but trigger it from verified provider events and coalesce bursts of events into one durable job per inbox.
- Add provider-watch lifecycle management: registration after connection, secure event validation, renewal before expiry, and safe fallback when a provider watch cannot be maintained.
- Retain daily incremental monitoring as reconciliation for missed events, expired watches, and provider delivery failures.
- Make automatic monitoring observable in Inbox Intelligence: state whether monitoring is active, show the last successful check, explain connection or watch failures, and reframe the manual control as an optional “Check now.”
- Keep automatic scans quiet while no actionable discovery exists; use the existing notification policy only for consented terminal outcomes.

## Capabilities

### New Capabilities

- `push-inbox-monitoring`: Verified Gmail and Microsoft mailbox-event intake that schedules safe, debounced incremental scans and manages provider-watch lifecycle.
- `inbox-monitoring-status`: User-facing inbox monitoring health, last-check state, fallback state, and optional manual check controls.

### Modified Capabilities

- `inbox-scan-outcome-notifications`: Automatic, provider-triggered scans use the existing opt-in terminal outcome policy without sending progress alerts for every mail event.
- `inbox-intelligence-dashboard`: The dashboard communicates continuous monitoring rather than presenting manual scanning as the primary workflow.

## Impact

- Affects `email-scan`, OAuth callback behavior, secure provider token handling, durable scan jobs, and Inbox Intelligence SwiftUI presentation.
- Adds server-side webhook endpoints and stored provider-watch state, with signed request validation, event deduplication, retry/renewal jobs, and operational monitoring.
- Requires Google Cloud Pub/Sub/Gmail watch configuration and Microsoft Graph webhook/subscription configuration, plus Supabase secrets and scheduled renewal/reconciliation invocations.
- Preserves read-only mail scopes, the current privacy-minimized cursor pipeline, review-first subscription changes, and no raw-email storage.
