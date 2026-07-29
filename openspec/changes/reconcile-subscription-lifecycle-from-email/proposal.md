## Why

Inbox discovery currently identifies individual billing events, but it does not determine whether their merchant represents a subscription that is still active. During an initial historical scan, an old receipt can be proposed as a new subscription even when a later cancellation or expiry email exists. Cancellation, renewal, and receipt messages are stored and reviewed independently, so the product cannot reliably distinguish a current recurring commitment from past activity.

The result is a high-cost trust failure: people are asked to add subscriptions they no longer use. Discovery should prioritize correctness about a subscription's current lifecycle state over recall of historical billing messages.

## Proposed Change

- Add a deterministic lifecycle-reconciliation layer after structured per-message extraction and before review candidates are created.
- Preserve immutable email-derived billing events, including provider source-received time, then group and order them by canonical merchant identity.
- Compute an evidence-backed lifecycle classification for each merchant: `current`, `ended`, or `uncertain`.
- Let later explicit cancellation, expiry, or termination evidence resolve earlier receipts and renewal events as ended rather than creating an add/update proposal.
- Require current evidence before creating an actionable add/update candidate: an explicit future renewal, or a recent recurring charge whose expected renewal window remains open and has no later ending event.
- Keep historical and uncertain findings out of the main action queue while retaining a privacy-minimized audit trail and optional explanation.
- Reconcile pending candidates again when a newly scanned event changes the merchant's lifecycle, so stale add/update proposals are automatically resolved without mutating subscriptions.
- Add durable user feedback for false-positive or unused merchants, such as “I don’t use this anymore,” with merchant-level suppression that does not rely on ignoring a single message.
- Define deliberate mailbox coverage for lifecycle evidence, including how non-Inbox or automatically archived provider messages are handled on incremental scans.
- Add fixtures and measurements for cancellation-after-receipt, expiry, annual billing, paused service, renewal after cancellation, missing-cancellation, conflicting timestamps, and user suppression.

## Capabilities

### New Capabilities

- `subscription-lifecycle-reconciliation`: Derive a current, ended, or uncertain lifecycle state from chronologically reconciled email billing evidence.
- `subscription-discovery-suppression`: Let a person persistently suppress future discovery proposals for a merchant they no longer use.

### Modified Capabilities

- `ai-email-subscription-discovery`: Create add/update review candidates only when lifecycle reconciliation finds sufficient current evidence; preserve non-actionable historical evidence without presenting it as a subscription to add.
- `billing-event-review`: Resolve stale pending candidates when newer lifecycle evidence supersedes them, and expose a clear explanation for an ended or suppressed merchant.

## Scope and boundaries

This change remains review-first: it does not automatically add, cancel, reactivate, or modify a subscription. It does not infer cancellation merely because no newer email is found. Lack of current evidence produces an uncertain or historical state, not an automatic end state.

The change does not add provider write permissions, vendor cancellation, attachment analysis, mail search beyond an explicitly documented coverage policy, or a free-form mailbox assistant.

## Expected impact

- Postgres: source-event timing, lifecycle/reconciliation state, candidate-resolution metadata, and user-owned merchant suppression records.
- Edge Functions: deterministic event ordering, lifecycle reduction, pending-candidate invalidation, and suppression-aware candidate creation.
- iOS: a calmer review queue focused on current subscriptions, with understandable history/suppression controls when needed.
- Quality: redacted lifecycle fixtures, deterministic reducer tests, reconciliation/idempotency tests, and product metrics for false-positive adds and suppression rate.

## Open questions

- What time window and grace period should qualify a recurring charge as current when an email does not state a future renewal date?
- Should ended and uncertain findings be visible in a separate history view, or remain hidden unless a person asks to inspect them?
- Should “I don’t use this anymore” suppress a merchant indefinitely, until the person reverses it, or for a chosen time period?
- Which mail folders/labels should be included for incremental lifecycle evidence while preserving the read-only, minimized-access promise?
