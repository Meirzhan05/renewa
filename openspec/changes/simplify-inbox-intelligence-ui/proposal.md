## Why

Inbox Intelligence currently presents its internal operations as a large dashboard: scan metrics, timelines, background state, learning history, connections, alerts, and privacy guidance compete with the one thing a person needs to know—whether there is a subscription change to review. The page needs to become a calm, proactive assistant that stays quiet when nothing needs attention and makes the next meaningful decision unmistakable.

## What Changes

- Replace the dashboard-style landing composition with an assistant-first Inbox Intelligence home that prioritizes the current outcome and pending reviewable discoveries.
- Collapse routine healthy/monitoring state into a compact status treatment; show scan progress only while a scan is genuinely active.
- De-emphasize manual scanning as an on-demand fallback rather than the page's primary purpose.
- Move inbox connections, alerts, reconnect/disconnect, scan history, paused suggestions, and privacy details into an Inbox settings/detail route.
- Move non-actionable scan learning and diagnostic metrics out of the default landing flow while retaining privacy-safe access to those details when needed.
- Preserve existing review, OAuth, automatic monitoring, notifications, privacy boundaries, and recoverable error behavior.

## Capabilities

### New Capabilities

- `inbox-intelligence-assistant-home`: A focused Inbox Intelligence landing experience that communicates only the current meaningful status, active scan progress, and reviewable discoveries, with secondary controls progressively disclosed.

### Modified Capabilities

- None.

## Impact

- Affects `Renewa/EmailScanView.swift`, Inbox Intelligence presentation state, navigation, accessibility labels, and supporting SwiftUI sheets/routes.
- Reuses existing email-scan status, candidate review, provider connection, monitoring, notification, and privacy-safe evidence models; no provider API, OAuth scope, or database schema change is expected.
- Supersedes the landing-page composition planned in `redesign-inbox-intelligence-ui` while retaining its durable state, local-error, and bounded-loading work.
