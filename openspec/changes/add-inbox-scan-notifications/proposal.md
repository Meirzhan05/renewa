## Why

Inbox Intelligence already continues scans after the app leaves the foreground, but people have no timely way to learn that a scan has completed, found reviewable discoveries, found nothing new, or needs an inbox reconnection. Manual scans also lack a system-level progress surface, leaving the work feeling opaque once someone switches away from Renewa.

## What Changes

- Add opt-in Inbox Intelligence outcome alerts for completed scan batches: reviewable discoveries found, no new discoveries, and inbox authorization failures that require reconnection.
- Add a Live Activity for user-initiated scans that shows truthful scan stage, messages checked, connected-inbox completion, and a percentage only when the provider supplies a reliable total.
- Add a user-owned notification preference, device/APNs registration, durable delivery outbox, delivery attempts, deduplication, retries, and invalid-token cleanup.
- Deep-link final alerts and completed Live Activities to Inbox Intelligence, where the app fetches current authenticated scan state before displaying candidates.
- Keep automatic daily scans quiet while running; they may deliver only one opted-in terminal outcome alert per completed batch.
- Keep notification payloads privacy-minimized: no raw email content, evidence snippets, model output, credentials, or subscription mutations.

## Capabilities

### New Capabilities

- `inbox-scan-outcome-notifications`: Deliver one consented, deduplicated, privacy-minimized APNs alert for actionable or explicitly requested terminal scan outcomes.
- `inbox-scan-live-progress`: Show user-initiated inbox scan progress through an in-app state and a server-updated iOS Live Activity without inventing unsupported percentage progress.

### Modified Capabilities

- None.

## Impact

- Affects the iOS app lifecycle, notification permission UX, Inbox Intelligence routing, and a new Live Activity/widget extension.
- Adds owner-scoped Supabase tables, RLS policies, migration(s), and an authenticated device-registration API.
- Adds an APNs delivery adapter and dispatcher Edge Function, using Apple push credentials stored only as Supabase secrets.
- Extends the existing `email-scan` Function at durable batch lifecycle boundaries, while preserving its review-first, read-only mail boundary.
- Requires Apple Push Notifications and Live Activities capabilities plus production-device APNs verification.
