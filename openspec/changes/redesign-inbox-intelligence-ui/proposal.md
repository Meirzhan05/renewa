## Why

Inbox Intelligence currently exposes scanning controls and individual review cards, but it does not clearly represent the work a scan performed or the difference between “no action needed” and “nothing happened.” This makes a successful, cautious scan feel empty and leaves people uncertain about connection health, background monitoring, and what they should do next.

## What Changes

- Redesign the Inbox Intelligence landing experience around scan health, user actions, and privacy-minimized learning rather than a static scanner hero.
- Add a durable scan summary that communicates connection state, last-run outcome, meaningful stage metrics, and whether background monitoring is active.
- Present actionable subscription proposals separately from non-actionable outcomes such as ended, uncertain, or withheld evidence.
- Add a scan-detail experience with privacy-minimized chronological evidence and clear explanations for why an item requires review, needs more evidence, or is safely excluded.
- Replace indefinite skeleton states with explicit loading, scanning, empty, and recoverable-error states.
- Keep provider credentials, raw email text, raw model output, and hidden policy internals out of the UI.

## Capabilities

### New Capabilities

- `inbox-intelligence-dashboard`: A trustworthy dashboard and scan-detail experience that makes Inbox Intelligence status, findings, safeguards, and next actions understandable.

### Modified Capabilities

- None.

## Impact

- Affects the SwiftUI Inbox Intelligence screens, scan presentation state, navigation, loading/error handling, and accessibility labels.
- Reuses existing scan status, connection, candidate, evidence, and lifecycle data; may require small read-model/API additions for aggregate scan outcomes and non-actionable evidence summaries.
- Does not change OAuth scopes, mutation policy, the AI extraction model, or storage of raw email content.
