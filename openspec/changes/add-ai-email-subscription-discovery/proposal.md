## Why

Renewa already has a proof-of-concept inbox scan that retrieves likely billing emails, sends a large batch to one model, accepts model-reported confidence above a fixed threshold, and immediately mutates subscriptions. That proves the product direction, but it is not yet a trustworthy production boundary: scans are synchronous and capped, later scans repeat mailbox work, malformed model output is not runtime-validated, one connected inbox is processed per request, and ambiguous additions, price changes, or cancellations can be applied without user review.

Subscription discovery should behave like a trusted assistant. AI should extract bounded billing-event candidates from minimized email content, while deterministic code validates, reconciles, and controls every database effect. Users should be able to review uncertain discoveries and understand what Renewa found without exposing more mailbox data than necessary.

## What Changes

- Replace the synchronous all-in-one email scan with an authenticated scan coordinator and durable, idempotent jobs per connected inbox. The client starts a scan, observes persisted progress, and can recover after the initiating request or app session ends.
- Add provider-specific incremental synchronization. Initial scans use a bounded lookback with pagination; later Gmail and Microsoft scans continue from stored history or delta cursors instead of rereading the same mailbox window.
- Separate cheap candidate selection from content retrieval. Renewa first evaluates bounded message metadata and snippets, then fetches, sanitizes, truncates, and transiently processes full content only for likely billing messages.
- Use one constrained AI extractor per message or small merchant-local batch with a versioned, runtime-validated schema. The extractor may identify an event or explicitly abstain; it does not receive tools and cannot mutate user data.
- Add an optional constrained verification pass only when deterministic validation identifies a specific ambiguity. This is a targeted second opinion, not a general multi-agent pipeline or autonomous decision-maker.
- Add deterministic validation and reconciliation for message identity, merchant identity, amounts, currencies, billing cycles, dates, event conflicts, and matches to existing subscriptions. Model-reported confidence is advisory rather than sufficient authorization.
- Persist immutable detected billing events separately from proposed subscription changes. Each candidate records its validation outcome, matched subscription when any, review state, schema/model versions, and a short non-verbatim evidence summary.
- Add a review-first inbox experience where users can confirm, edit, or ignore proposed subscriptions and material changes. Additions, cancellations, reactivations, merchant mismatches, and unusual price changes require confirmation in the initial release.
- Replace provider-specific merchant keys as the primary reconciliation identity with a provider-independent canonical merchant and alias strategy, while preserving source message deduplication and compatible brand-logo enrichment.
- Add explicit inbox connection management, including connection status, last successful synchronization, disconnect, provider-token revocation where supported, and deletion of retained scan metadata.
- Add bounded retries, per-user rate limits, partial-failure reporting, structured operational telemetry, and a representative redacted fixture/evaluation suite that measures extraction precision, recall, field accuracy, correction rate, latency, and model cost.
- Align implementation and documentation on the selected AI provider, API mode, model identifier, storage/retention behavior, and production data-control requirements.

This change does not add attachment analysis, mail write permissions, automatic vendor cancellation, web browsing by the model, a free-form mailbox assistant, or autonomous multi-agent control of subscriptions. Scheduled background discovery and provider push notifications may be added later after the on-demand incremental pipeline is measured.

## Capabilities

### New Capabilities

- `ai-email-subscription-discovery`: Incrementally retrieve likely billing mail and produce privacy-minimized, schema-validated subscription-event candidates through a constrained AI extraction pipeline.
- `billing-event-review`: Present proposed subscription additions and changes with evidence, permit correction or rejection, and apply only user-confirmed effects in the initial release.
- `mail-connection-controls`: Expose connected-inbox health and synchronization state and support safe disconnect, credential revocation, and scan-data cleanup.

### Modified Capabilities

- `subscription-brand-logos`: Resolve confirmed email discoveries through the provider-independent canonical merchant identity before persisting a reviewed brand identifier.

## Impact

- Affects `Renewa/EmailScanView.swift`, `AppStore.swift`, `SupabaseClient.swift`, `Models.swift`, and new scan-progress and candidate-review presentation models/views.
- Refactors `supabase/functions/email-scan` into coordination and worker responsibilities and adds shared provider adapters, content minimization, extraction validation, merchant reconciliation, and model-provider interfaces.
- Adds forward-only migrations for provider sync state, queued scan work, processed-message fingerprints, reviewable subscription candidates, canonical merchant linkage, model/prompt versions, and connection lifecycle metadata.
- Retains the existing read-only Gmail and Microsoft delegated permissions, encrypted server-side credentials, authenticated Functions, ownership RLS, and immutable billing-event audit trail.
- Requires production decisions for the durable queue/worker schedule, provider-token revocation behavior, AI-provider retention controls, evidence and diagnostic retention periods, per-user limits, and privacy/App Store disclosures.
- Requires backend tests for OAuth ownership, incremental cursors, pagination, idempotency, retries, prompt-injection resistance, schema rejection, merchant matching, event conflicts, review authorization, RLS isolation, revocation, and account-deletion cascades.
- Requires a redacted multilingual fixture corpus covering renewals, trials, invoices, price changes, cancellations, one-time purchases, marketing, phishing, ambiguous merchants, missing currencies, and conflicting dates before any automatic application is considered.
