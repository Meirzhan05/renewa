## Context

Inbox discovery already extracts bounded, privacy-minimized billing events and stores them in `detected_billing_events`. It then creates a review candidate for each valid event. An initial Gmail bootstrap covers up to 365 days, so an old receipt can become an add candidate even when later events establish that the service ended. Event rows do not retain the provider message's received timestamp, and no reducer evaluates all evidence for a merchant before a candidate is shown.

The existing system is intentionally review-first. This design preserves that boundary: lifecycle reconciliation determines whether discovery should create or withdraw a proposal; it never automatically applies a subscription mutation.

## Goals / Non-Goals

**Goals:**

- Determine whether email evidence supports a currently active, explicitly ended, or uncertain merchant lifecycle.
- Prevent historical evidence from producing add/update candidates.
- Let explicit later ending evidence supersede earlier activity and stale pending candidates.
- Give people a durable merchant-level “I no longer use this” suppression control.
- Preserve immutable, privacy-minimized evidence and deterministic, idempotent review behavior.

**Non-Goals:**

- Inferring a cancellation from the absence of mail.
- Automatically canceling, adding, reactivating, or editing a subscription.
- Persisting raw email content, adding mail write access, or extending provider permissions.
- Building a general mailbox history UI in this change.

## Decisions

### Derive lifecycle from the immutable event stream

`detected_billing_events` remains the source of truth. A pure lifecycle reducer receives all events for one user and canonical merchant key, ordered by a provider-supplied `source_received_at` timestamp. It returns `current`, `ended`, or `uncertain`, plus a non-sensitive reason and the event that supports the outcome.

This avoids a mutable lifecycle table that can become inconsistent when late mail, retrying jobs, or reconnected inboxes introduce older events. A new index makes per-merchant event reads bounded and efficient. A cached/materialized view was considered, but the small per-merchant event set and need for straightforward retries favor recomputation.

### Use explicit ending evidence and conservative current evidence

A later `canceled` event takes precedence over earlier creation, renewal, and price-change evidence. It produces an `ended` result. The reducer does not infer an end from silence.

For non-ended merchants, `current` requires one of:

- an explicit future renewal date on a paid recurring event; or
- a paid creation/renewal/price-change event whose derived next renewal date from its billing cycle is still today or later.

Trials, events without a positive amount/currency/cycle, past-due derived renewals, conflicting dates, and ambiguous evidence are `uncertain`. This deliberate precision bias favors not surfacing a subscription over falsely asking a person to add a service they stopped using.

### Reconcile before creating and confirming candidates

After a new event is persisted, the worker loads merchant-local history and reduces it before creating a candidate:

- `current`: create one add/update candidate only when the merchant is not suppressed.
- `ended` with one matched active subscription: create or retain a review-required cancellation candidate.
- `ended` without a matched subscription, or `uncertain`: persist the event but create no action candidate.

When an ending or uncertain result supersedes a merchant, pending add/update candidates for that merchant are marked ignored with a system resolution reason. Candidate confirmation repeats the lifecycle check so a stale screen cannot apply an outdated proposal. This is preferred over deleting candidates because it retains an auditable, non-sensitive explanation.

### Add reversible merchant suppression

A user-owned `merchant_discovery_suppressions` table stores canonical merchant key, an optional reason, and timestamps. A candidate-level “I don’t use this” action inserts or updates the suppression and resolves all pending non-cancellation candidates for that merchant. Future current evidence will be retained as immutable events but will not enter the action queue until the person removes suppression.

Suppression intentionally does not modify an existing subscription and does not hide an explicit cancellation candidate for an already tracked active subscription. That preserves user control over financial state while reducing repeat false positives.

### Make mailbox coverage explicit

The initial Gmail scan searches recent mail broadly while incremental Gmail history is currently limited to Inbox additions; Microsoft uses the Inbox delta feed. This change documents that discovery is best-effort Inbox-focused after bootstrap. It does not silently broaden incremental access. A later change can add an opt-in broader-folder policy after provider and privacy review.

## Risks / Trade-offs

- [Historical annual service is still active but has no explicit future date] → Deriving its next renewal from the last paid event and yearly cycle retains it only until that projected date; date conflicts become uncertain rather than an add.
- [Cancellation message is archived or unavailable] → Do not infer ended status; allow durable user suppression and disclose Inbox-focused incremental coverage.
- [Late event changes a prior result] → Recompute from the full merchant-local event stream and resolve, rather than delete, stale candidates.
- [Merchant aliases split evidence] → Continue canonical-key and brand matching, but leave ambiguous merchant matches uncertain and reviewable.
- [Suppression hides a genuine future restart] → Make suppression reversible and retain new events so a person can re-enable discovery.

## Migration Plan

1. Add `source_received_at` to detected events, backfill it from the best available event/creation timestamp, and index user, canonical merchant key, and source time.
2. Add candidate system-resolution metadata and the user-owned merchant-suppression table with RLS and service-role grants.
3. Deploy lifecycle reducer, candidate reconciliation, and suppression actions before enabling the updated client UI.
4. Existing pending candidates remain valid until a new event for their merchant causes reconciliation; no subscription rows are changed by migration or reconciliation.

Rollback consists of stopping the updated Function deployment. The new columns and suppression table are additive and can remain harmlessly; no destructive rollback is required.

## Open Questions

- Should a person be able to view ended/uncertain evidence in a separate audit/history surface in a later change?
- What product copy best communicates an Inbox-focused incremental scan without suggesting exhaustive mail analysis?
- Should a later opt-in broader-folder mode scan Gmail All Mail and non-Inbox Microsoft folders?
