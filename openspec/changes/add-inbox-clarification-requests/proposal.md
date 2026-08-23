## Why

Inbox Intelligence currently protects people from uncertain AI output by withholding evidence that cannot safely create an actionable subscription candidate. That safety rule prevents false positives, but it also leaves answerable questions unresolved—for example, whether a recent receipt represents an active subscription or whether an unfamiliar descriptor belongs to an existing service.

People should be able to resolve these bounded ambiguities directly in Inbox Intelligence, so the assistant can improve its future suggestions without inventing a subscription or turning every low-confidence email into an interruption.

## What Changes

- Add durable Inbox clarification requests for answerable uncertainty in merchant identity, subscription lifecycle, and a material billing field.
- Present one prioritized **Quick question** in the main Inbox flow, below inbox status and above handled activity; additional requests remain queued without overwhelming the page.
- Give every clarification a plain-language explanation, privacy-minimized evidence, and bounded response choices such as **Yes**, **No**, and **Not sure**.
- Persist the person's answer and apply only the safe consequence it supports: create or revise a review proposal, record a merchant relationship, suppress a suggestion, or retain uncertainty.
- Keep weak, stale, marketing-like, or non-actionable evidence out of the clarification queue.
- Preserve the existing confirmation sheet for actionable subscription proposals and ensure no clarification answer silently adds, changes, or cancels a subscription.

## Capabilities

### New Capabilities

- `inbox-clarification-requests`: Create, prioritize, display, and resolve bounded questions that let a person help Inbox Intelligence disambiguate subscription evidence.

### Modified Capabilities

- None.

## Impact

- **iOS:** Inbox state, primary review section, and a focused clarification detail flow in `Renewa/EmailScanView.swift`, plus models and AppStore request handling.
- **Backend:** New persistent clarification state and answer outcomes; email-scan lifecycle and identity resolution must create questions only for eligible ambiguity.
- **Data and privacy:** A migration, RLS-safe read access, and privacy-minimized API payloads are required. Raw email content and model output remain unavailable to the app.
- **Evaluation:** Tests must prove prioritization, answer idempotency, no subscription mutation without explicit proposal confirmation, and quiet handling of non-actionable uncertainty.
