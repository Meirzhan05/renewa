## Context

Renewa already persists a Gmail history cursor or Microsoft Graph delta link after a scan and has a daily automatic-scan path. It does not currently receive provider mailbox events. As a result, automatic behavior depends on a scheduled server call, while the Inbox Intelligence dashboard still foregrounds a manual scan.

The design must preserve read-only OAuth scopes, encrypted server-only tokens, durable scan jobs, review-first subscription mutations, and the rule that raw message bodies and raw model output are not stored. Gmail and Microsoft have materially different delivery and expiry models, so the shared scan worker cannot assume a generic webhook is sufficient.

## Goals / Non-Goals

**Goals:**

- Start an incremental, cursor-based scan soon after a connected mailbox reports new activity, even when the iOS app is closed.
- Reliably coalesce noisy or duplicate provider events into one durable scan per inbox without losing mailbox changes.
- Maintain Gmail and Microsoft provider watches/subscriptions before expiry and recover safely from provider delivery or authorization failures.
- Retain daily reconciliation as a bounded backstop and communicate monitoring health truthfully in the app.
- Keep automatic scans quiet until a consented terminal outcome warrants an existing notification.

**Non-Goals:**

- Reading, retaining, or sending every incoming message to the AI extractor.
- Claiming real-time delivery guarantees from providers.
- Performing subscription mutations without user confirmation.
- Replacing the existing manual “Check now” recovery control or the existing durable email-scan worker.
- Adding a desktop/background iOS mailbox listener; monitoring remains server-owned.

## Decisions

### Treat provider events as wake signals, not email payloads

Gmail Pub/Sub notifications and Microsoft Graph webhook notifications SHALL only identify a connected mailbox or its provider resource. The server will use the existing Gmail history or Microsoft delta cursor to determine the changed messages, then retain the existing metadata filter and bounded AI extraction pipeline.

This avoids trusting provider event payloads as complete mailbox state and prevents every event from causing full email retrieval. Directly parsing event payloads was considered, but rejected because notifications can be duplicated, delayed, coalesced, or incomplete.

### Use one server-owned monitoring coordinator

Add a provider-neutral monitoring service and persisted watch state for each connection: provider resource identifier, encrypted or non-sensitive provider continuation values as appropriate, expiration, client-state/verification material, last event received, last renewal attempt, health state, and bounded error metadata. OAuth completion provisions monitoring; disconnect and account deletion remove it.

The coordinator exposes provider-specific adapters:

- Gmail: create and renew a Gmail `watch` that delivers to a Renewa-controlled Pub/Sub topic; validate the authenticated Pub/Sub delivery identity before accepting a history notification.
- Microsoft: create and renew a Microsoft Graph mail subscription; answer the validation-token handshake and verify the configured client state on later notifications.

A shared abstraction keeps the scan worker provider-neutral while leaving authentication and renewal details in provider adapters. A generic unauthenticated webhook was rejected because it would weaken source validation and make expiry handling ambiguous.

### Debounce events into durable incremental scans

Webhook handling persists an idempotent event receipt and marks the matching connection due after a short debounce window (initially two minutes). A server-only dispatcher claims due connections, creates or reuses the existing scan batch/job, and records the scheduling decision. Multiple events for one connection during the window result in one scan; events arriving while a scan runs result in one follow-up check after it completes.

The existing cursors remain the source of truth, so duplicates are harmless and an event cannot advance a cursor before successful processing. An immediate scan per event was rejected because mailbox bursts would amplify provider calls and model work.

### Keep scheduled reconciliation and add watch maintenance

Scheduled server work has two separate responsibilities:

1. Reconcile due connections at least daily using the existing automatic scan path, including connections with unhealthy or expired watches.
2. Renew provider watches before their provider-defined expiry, retry transient renewal failures with bounded backoff, and surface reconnect-required when tokens or consent are invalid.

The jobs use protected, server-only invocation and batch limits. Daily polling alone was rejected as the primary mechanism because it makes a “watching new email” promise inaccurate; push alone was rejected because provider notifications are not a complete-delivery guarantee.

### Bound historical discovery and prioritize recent evidence

The first discovery pass SHALL query the most recent 180 days of a connected mailbox rather than treating the entire mailbox as equally relevant. The Gmail query and Microsoft delta bootstrap MUST apply that bound on every historical page. If a provider cursor expires, recovery SHALL rescan the most recent 90 days before rebuilding the cursor.

This makes recent paid renewals the primary evidence for current subscriptions, contains provider and model work, and prevents distant receipts from dominating the first review queue. Provider-event and daily reconciliation scans remain cursor-based and do not re-read the historical window.

### Make monitoring—not manual scanning—the dashboard’s primary story

Inbox Intelligence will display a distinct monitoring health state: actively monitoring, checking/reconciling, degraded but protected by daily reconciliation, or reconnect required. It will show a privacy-minimized last successful check and a clear explanation of degraded state. “Check now” remains available as an optional user action; it is not described as the expected way to discover new subscriptions.

The prior “Scan connected inbox” primary framing is rejected because it suggests the user must operate the service manually.

### Preserve notification restraint

Provider events and automatic scans do not create progress notifications per email. The existing opt-in outcome policy is invoked only after a terminal batch state: reviewable discovery, explicit no-candidate completion when enabled, or reconnect-required. In-app status may refresh when the user opens the dashboard.

## Risks / Trade-offs

- [Provider watch expiry or delivery gaps] → Renew early, retain daily cursor reconciliation, and expose a truthful degraded state.
- [Forged or replayed webhook calls] → Verify provider delivery identity/client state, persist deduplication keys, enforce timestamps where supplied, and never accept a user token as webhook authority.
- [Rapid mailbox bursts create redundant work] → Per-connection debounce, unique due-work records, job claiming, and cursor-based idempotency.
- [History cursor expires or Graph delta is invalidated] → Use the existing bounded recovery scan, retain an operational error, and avoid silently treating the inbox as current.
- [Webhook setup requires external cloud configuration] → Keep provider credentials, Pub/Sub/Graph endpoints, client-state values, and monitor secrets server-only; add deployment verification before enabling the monitoring claim in UI.
- [A user expects instant discovery] → Use language such as “monitoring new email” and “checked recently,” not a real-time guarantee.

## Migration Plan

1. Add monitoring-state, event-receipt, and due-work schema with RLS/service-role boundaries, without enabling events for existing connections yet.
2. Deploy and configure the protected Gmail Pub/Sub receiver, Microsoft validation/webhook receiver, provider credentials, and renewal/reconciliation scheduler.
3. Provision/renew watches for an internal test cohort; validate duplicate events, expired watches, OAuth failures, and cursor recovery.
4. Enable automatic watch provisioning for new connections and backfill existing eligible connections in bounded batches.
5. Ship the dashboard health wording only after the corresponding server monitoring state is trustworthy.
6. Roll back by disabling watch provisioning and event intake; daily reconciliation and manual checks continue to use the existing cursor pipeline. Retain state for safe re-enable, and delete provider subscriptions when disabling permanently.

## Open Questions

- Which Supabase/Google Cloud project will own the Gmail Pub/Sub topic and verified push identity?
- Which public HTTPS domain and validation path will Microsoft Graph call, and what subscription resource/lifetime is approved for the product tenant?
- What user-facing freshness target is appropriate after an event: “within minutes,” “same day,” or no numeric promise?
- Should people be able to turn continuous inbox monitoring off while retaining the manual check, or does disconnect remain the sole opt-out?
- Does “no candidates” remain an opt-in notification for automatic scans, or should it only be visible in the dashboard activity history?
