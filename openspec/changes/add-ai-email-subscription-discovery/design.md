## Context

`email-scan` currently authenticates a user, chooses one mailbox connection, retrieves at most 100 messages, sends the messages together to DeepSeek, filters the unvalidated response by model-reported confidence, and immediately upserts or cancels subscriptions. The request remains open for the entire scan. Gmail and Microsoft tokens are encrypted at rest, Functions use the service role behind authenticated entry points, and scan/event tables already provide a user-owned audit foundation.

This change crosses the SwiftUI client, Supabase Functions, Postgres schema, mail-provider APIs, AI provider, privacy controls, and testing. Mail content is sensitive and model output is untrusted, so the design must minimize disclosure, remain idempotent under retries, and keep database effects deterministic.

## Goals / Non-Goals

**Goals:**

- Make on-demand scans asynchronous, resumable, incremental, multi-connection, and observable.
- Fetch full mail content only for bounded billing candidates and never persist raw bodies.
- Extract one message at a time through a versioned structured schema with runtime validation.
- Reconcile provider-independent merchant candidates against existing subscriptions without allowing the model to mutate data.
- Require review for additions, cancellations, reactivations, and material changes.
- Support connection health, disconnect, token revocation, and scan-metadata cleanup.
- Add pure backend coverage and iOS presentation/model tests.

**Non-Goals:**

- Attachments, mail write access, vendor cancellation, browsing, a mailbox chatbot, scheduled scans, or push notifications.
- Autonomous multi-agent decision-making.
- Automatic application of any newly detected event in this release.
- Retaining raw model input, raw model output, or email bodies for debugging.

## Decisions

### Table-backed jobs with opportunistic background processing

`email-scan` will create a scan batch, one run and durable job per connected inbox, then return immediately. `EdgeRuntime.waitUntil` will process the caller's queued jobs after the response. Starting or checking a scan also claims any retryable queued job for that user, so a terminated worker can resume later without duplicating applied work.

This avoids holding the iOS request open and provides durable state without adding a new infrastructure vendor. A future Supabase Cron invocation may drain retryable jobs globally, but scheduled discovery is outside this change.

### Provider-specific incremental adapters

Google bootstrap scans use bounded, paginated message listing and persist the mailbox `historyId`; later scans use `history.list` for added inbox messages and fall back to a short bounded bootstrap if the history cursor expires. Microsoft bootstrap and subsequent scans use the Inbox messages delta endpoint and persist the opaque `deltaLink`. Provider cursors advance only after successful processing.

Message metadata/snippets are evaluated before full content is retrieved. Fetch concurrency and total candidates are bounded to limit provider throttling, model cost, and Function duration.

### Multi-stage, single-extractor AI boundary

Deterministic code selects candidates, sanitizes HTML, strips control content, truncates text, and sends one message to the configured DeepSeek-compatible extraction adapter. The model returns JSON under a versioned schema and may abstain. Runtime validation checks exact enums, finite amounts, ISO currencies, real dates, message identity, lengths, and required fields.

A second constrained verification call is permitted only for a candidate with a named validation ambiguity and is disabled by default. General agents, tools, cross-message memory, and model-controlled side effects are excluded.

### Immutable events and reviewable proposals

Validated extraction results are persisted in `detected_billing_events`; `subscription_candidates` records the proposed action, canonical merchant key, possible subscription match, validation issues, and review state. Model confidence is stored for diagnosis but does not authorize a change.

Confirmation is handled by the authenticated Function in a transaction-like ordered operation: re-read candidate ownership/state, validate user edits, apply the deterministic subscription mutation, and mark the candidate/event applied. Retries are idempotent. Ignoring a candidate never changes a subscription.

### Conservative merchant reconciliation

The server builds a normalized, provider-independent merchant key and checks existing `canonical_merchant_key`, legacy email source keys, reviewed brand aliases, and normalized names. An exact unique match may be proposed; ambiguous or missing matches remain unresolved. The model cannot choose a subscription identifier.

Existing provider-specific source keys remain readable during migration. Confirmed new email subscriptions use a stable email source key derived from the canonical merchant key, while uniqueness is still enforced per user.

### Function-owned connection controls

Clients receive only redacted connection summaries. Disconnect attempts provider revocation, deletes the encrypted local credential regardless of an already-invalid remote token, and cascades sync/job state. Historical scan/event records remain until explicit scan-history cleanup or account deletion so subscription provenance is not silently erased.

### Explicit AI provider truth

The implementation and documentation will describe the configured DeepSeek-compatible Chat Completions endpoint, JSON response mode, model identifier, and lack of raw payload retention by Renewa. A provider-neutral extraction interface isolates future replacement, but this change does not claim OpenAI-specific Structured Outputs or retention flags.

## Risks / Trade-offs

- [Background task terminates before completion] → Persist every job transition and resume queued/retryable work on later start/status requests.
- [Provider cursor expires] → Record a bounded fallback scan and replace the cursor only after success.
- [Function duration is exceeded] → Bound pages, full-content candidates, concurrency, and messages per worker pass; leave remaining work queued.
- [Candidate filter misses localized billing mail] → Use a multilingual signal list, measure recall with fixtures, and preserve bounded bootstrap scanning.
- [Model returns plausible but false data] → Runtime validation, deterministic reconciliation, mandatory review, and explicit abstention.
- [Duplicate merchant names collide] → Treat canonical keys as match hints rather than globally unique identities and require review for ambiguous matches.
- [Revocation endpoint is unavailable] → Remove the encrypted local token, report remote revocation as best-effort, and let provider expiry complete the boundary.
- [More server state increases complexity] → Keep state machines small, indexed, user-owned, and covered by transition/idempotency tests.
- [Review friction reduces activation] → Present concise evidence and editable fields while measuring confirmation and correction rates before considering automation.

## Migration Plan

1. Add enums, sync state, durable jobs, candidates, canonical merchant columns, scan progress, RLS, indexes, grants, and cascade behavior.
2. Deploy the refactored authenticated `email-scan` Function before the new client. Its start response remains isolated to the new client release.
3. Ship the client progress, review, connection, and disconnect experience.
4. Observe scan completion, cursor fallback, candidate confirmation, correction, and error metrics with automatic application disabled.
5. Roll back the client to manual scan entry if needed; queued data is additive. Roll back Function behavior by disabling new job creation while retaining events/candidates for audit. Do not reverse the additive migration.

## Open Questions

- What evidence-retention duration should be selected for production after legal/privacy review?
- Should scheduled incremental scanning become a per-connection opt-in after on-demand precision and cost targets are met?
- What measured precision threshold would justify automatic renewal-date updates for previously confirmed merchants in a later change?

