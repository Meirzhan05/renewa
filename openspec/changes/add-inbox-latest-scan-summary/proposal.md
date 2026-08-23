## Why

The simplified Inbox Intelligence home is calm, but when no change needs review it does not provide enough evidence that the assistant is useful or that a recent inbox check did meaningful work. A compact latest-check summary will make monitoring feel trustworthy without restoring the previous operational dashboard.

## What Changes

- Add a compact, privacy-minimized Latest check card to the healthy and completed Inbox Intelligence home states.
- Show the connected provider, completion time, trustworthy checked-message and likely-billing counts when available, and a plain-language result.
- Add a Scan details route from the latest-check card for progressively disclosed safe history and existing non-actionable outcomes.
- Refine the landing subtitle so it describes the connected-inbox activity rather than repeating the monitoring status.
- Keep the current compact state card, review queue, settings sheet, and manual check behavior unchanged.

## Capabilities

### New Capabilities

- `inbox-latest-scan-summary`: A concise, privacy-safe proof-of-work summary that lets people understand the most recent Inbox Intelligence check without exposing an operational dashboard.

### Modified Capabilities

- None.

## Impact

- Affects the Inbox Intelligence SwiftUI landing view and its presentation-state tests.
- Reuses the existing authenticated scan status fields and secondary Scan details route; no mailbox content, provider scope, API, or database change is expected.
- Builds on `simplify-inbox-intelligence-ui` and must preserve its assistant-first hierarchy.
