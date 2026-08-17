## Context

`email-scan` already runs durable, resumable jobs for connected inboxes. A scan can continue after the iOS app leaves the foreground and daily monitoring starts scans without a device session. The Function persists candidates and exposes batch status, but it has no device registration, notification preference, delivery record, or system-level progress surface.

The notification layer must preserve the existing read-only, review-first mailbox boundary. It must also distinguish a user-initiated scan, which merits temporary progress, from automatic monitoring, which must not unexpectedly occupy the Lock Screen or Dynamic Island.

## Goals / Non-Goals

**Goals:**

- Notify a consenting user once when a completed scan batch has reviewable discoveries, completes with no new discoveries, or needs an inbox reconnection.
- Show accurate in-app and Lock Screen/Dynamic Island progress for a scan the user explicitly starts.
- Make delivery durable, deduplicated, retryable, auditable, and safe across multiple iOS devices for one account.
- Keep push and Live Activity payloads free of raw mail, evidence excerpts, model output, credentials, and subscription fields.

**Non-Goals:**

- Notifications for every email, extraction, scan phase, or model call.
- Starting a Live Activity for automatic daily monitoring.
- Android, web push, Firebase Cloud Messaging, marketing notifications, rich media, or notification actions that mutate subscriptions.
- Claiming an exact percentage when a mail provider has not supplied a reliable total.

## Decisions

### Use direct APNs with native Apple frameworks

The iOS app will use `UserNotifications` for consent and ordinary remote notifications, and `ActivityKit` plus a WidgetKit extension for Live Activities. It will refresh its APNs device token on launch/sign-in and register it with an authenticated Renewa endpoint. A server-only APNs `.p8` authentication key, Team ID, Key ID, and bundle ID will be stored as Supabase secrets; the delivery adapter will mint short-lived ES256 provider tokens with Web Crypto and send directly to APNs.

Direct APNs is selected over Firebase/OneSignal because Renewa currently targets iOS and already has a Supabase Edge Function backend. It avoids a client SDK, third-party user/device data flow, and a second provider credential set. Firebase becomes a reasonable alternative only if Android or cross-platform notification analytics becomes a near-term product requirement.

### Separate persistent device installation and preference records from ephemeral Live Activity tokens

An owner-scoped `notification_device_installations` table will retain normal APNs token, platform, environment, permission state, last seen time, and disable time. A user can own multiple current devices. An owner-scoped `notification_preferences` record will include `inbox_scan_outcomes_enabled`; the explicit default will be disabled until the user enables Inbox Intelligence alerts in context after connection.

An owner- and batch-scoped `inbox_scan_live_activities` table will retain only an active ActivityKit push token, its activity identifier, batch, device installation, last reported state, and terminal timestamp. It is a distinct token type with a short lifetime and must never replace the normal device token.

### Generate terminal outcome notifications through a transactional outbox

The scan worker will not call APNs directly. Once every job in a `batch_id` has reached a terminal state, a server-owned finalization routine will calculate the terminal outcome from candidates created by that batch and the connection/job state. It will upsert one `notification_outbox` row with a stable `deduplication_key` such as `inbox-scan:<batch-id>:<outcome>`.

The result categories are:

- `review_ready` when the batch created one or more pending, review-eligible candidates;
- `no_new_discoveries` when it completed without such candidates;
- `reconnect_required` when a connected inbox cannot be read because authorization has expired or become invalid.

Each event stores only a user ID, batch ID, outcome, aggregate count, safe deep-link route, scheduling/lease metadata, and delivery status. It contains no raw email-derived text. This outbox design is selected over `EdgeRuntime.waitUntil` delivery because it survives worker retries, concurrent jobs, and temporary APNs failure without duplicate notifications.

### Use a scheduled dispatcher with leases, retries, and invalid-token cleanup

A protected `notification-dispatch` Edge Function will claim due outbox rows with an expiring lease, resolve enabled installations, send APNs requests, and write one `notification_deliveries` row per attempt. The existing `pg_cron`/`pg_net` pattern will invoke it frequently enough for timely results. It will use bounded exponential retry only for transient delivery failures. APNs invalid-token responses permanently disable the affected installation; a later app registration can reactivate it.

This makes delivery at-least-once internally but effectively once to each device through event and delivery idempotency keys. The inbox screen remains authoritative when a person opens the app.

### Reserve Live Activities for manual scans and use truthful progress

When a user starts a scan from Inbox Intelligence and the device allows Live Activities, iOS will start one local ActivityKit activity and register its push token with the server against the returned batch ID. The scan worker will update its stage only at durable progress boundaries (for example, queued, fetching, filtering, extracting, inbox complete). It will include scanned-message counts and completed/total inboxes.

Percentage is optional. It is emitted only for a provider/page sequence with a persisted, reliable total and a monotonic scanned count. Otherwise the UI will say, for example, “Finding likely billing mail · 8,421 messages checked” rather than fabricate a percentage. The server will end the Activity with the final safe outcome and a short dismissal window.

The dispatcher must not additionally send the same terminal alert to the device that has received a current Live Activity final state. Other enabled devices remain eligible for their normal alert. This avoids duplicate alerts for the same scan outcome.

### Treat notification taps as a route, not as a data channel

Ordinary notifications and the final Live Activity will carry only a versioned route such as `inbox-intelligence` plus a batch identifier. On tap, the app opens Inbox Intelligence and fetches current authenticated scan status. It must not display a candidate from notification payload, and a stale or deleted batch must fall back safely to the Inbox Intelligence overview.

## Risks / Trade-offs

- [No reliable provider total exists] → Show stage, count, and completed-inbox progress; omit percentage.
- [A user receives daily no-results alerts too often] → Keep outcome alerts opt-in and make the no-results category independently suppressible in a later preference expansion.
- [Multiple jobs finalize concurrently] → Finalize by batch with a unique outbox deduplication key and transactional/conditional writes.
- [APNs cannot deliver or a token changes] → Persist delivery results, retry transient failures, and disable invalid tokens until the app registers again.
- [Live Activity update limits or a device is offline] → Update only durable stage changes, display a stale state when needed, and keep the in-app status endpoint authoritative.
- [Notification payload leaks mailbox detail] → Restrict payloads to category/count/route data and add tests asserting prohibited fields are absent.
- [A user revokes permission] → Synchronize authorization state on app activation and suppress ordinary delivery without affecting scan behavior.

## Migration Plan

1. Add additive owner-scoped tables for preferences, installations, Live Activities, outbox events, and delivery attempts; enable RLS and service-role grants where required.
2. Add the iOS permission, device registration, routing, and manual Live Activity UI behind disabled outcome preferences.
3. Deploy the APNs adapter and protected dispatcher with secrets configured, then test sandbox and production APNs on physical devices.
4. Add batch finalization and Live Activity updates to `email-scan`; enable outcome alerts for an internal account first.
5. Monitor delivery failures, duplicate suppression, token invalidation, and opt-out rates before enabling the opt-in control broadly.
6. Roll back by disabling dispatch/finalization through configuration. Existing scans remain unaffected; outbox rows can be safely retained or marked cancelled, and device tokens can be deleted on sign-out/account deletion.

## Open Questions

- The first release uses one Inbox Intelligence outcome preference. Should no-results alerts become a separate user-facing preference at launch, or only if feedback shows daily monitoring is noisy?
- What final Live Activity dismissal duration best balances confirmation with Lock Screen clutter: immediate, 15 minutes, or the system default?
