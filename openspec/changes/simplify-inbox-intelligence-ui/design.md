## Context

The current Inbox Intelligence view is the product of several valid additions: scan health, scan progress, candidate review, non-actionable learning, inbox monitoring, connection controls, notification settings, suppressions, and privacy guidance. Putting all of them on one scroll makes the surface feel like a scanner control panel rather than a subscription assistant. The data and safety behaviors are already valuable; this change changes their presentation hierarchy, not the discovery pipeline.

The prior `redesign-inbox-intelligence-ui` change established durable server-driven state, bounded loading, privacy-safe learning data, and localized error handling. This design consumes those outcomes and replaces its landing-page composition with a smaller one.

## Goals / Non-Goals

**Goals:**

- Make the first screen answer one question: “Do I need to do anything?”
- Treat automatic monitoring as the default behavior and manual scanning as an optional fallback.
- Keep scan progress and failures visible only when they are relevant.
- Preserve access to account, notification, history, suppression, privacy, and diagnostic information without making it compete with subscription decisions.
- Retain existing provider-independent, privacy-minimized data and review protections.

**Non-Goals:**

- Changing email fetching, candidate extraction, monitoring cadence, provider OAuth scopes, or notification delivery.
- Removing the ability to manually check an inbox, manage connected accounts, pause suggestions, inspect safe evidence, or recover from an error.
- Exposing raw email content, sender addresses, model output, internal policy flags, or unsupported progress percentages.
- Creating a general app-wide notification centre.

## Decisions

### 1. Make the landing page a state-first assistant surface

The page will use a compact status surface rather than the current large, animated scan-health dashboard. Its mutually exclusive states are: no inbox, monitoring normally with no action, scanning, review ready, and needs attention. Each state contains a single concise outcome and, only where appropriate, a single primary action.

- No inbox: explain read-only connection and offer connection.
- Monitoring normally: state that the inbox is watched, with a short last-check line.
- Scanning: show the durable stage and checked-message count inline, plus that work continues when leaving the tab.
- Review ready: lead with the reviewable count and candidate cards.
- Needs attention: explain the affected connection and offer the recovery action.

Alternative considered: retain the large health card and remove a few sections. Rejected because the visual hierarchy would still frame routine operational state as the page’s primary content.

### 2. Put only reviewable discoveries in the default feed

The default content area will show pending candidates, each retaining its existing review and dismissal path. When there are none, it will show a calm empty/complete state rather than a “What we learned” history section. The wording will distinguish “no action needed” from “we found nothing,” without displaying scanner counters or underlying classifications.

Non-actionable evidence, scan counts, held-back ambiguities, validation skips, and lifecycle history remain available from a secondary Scan details route. They are not deleted or converted into active subscriptions.

Alternative considered: retain the learning section below a collapsed headline. Rejected because it requires every person to interpret information that deliberately does not require action.

### 3. Move operational controls into Inbox settings

An Inbox settings route, presented from the navigation bar’s overflow control, will own connected inbox cards, reconnect/disconnect, alert preference, Check now, paused suggestions, scan history/clear-history, and the full privacy explanation. The route keeps existing confirmations and accessibility behavior.

The landing page may link directly to the specific settings action required for a failure or no-inbox state. Normal monitoring does not expose a prominent “Check now” action.

Alternative considered: leave provider controls at the bottom of the landing scroll. Rejected because connection administration is occasional and visually dilutes the ongoing assistant experience.

### 4. Treat scanning as an inline temporary state

While work is in progress, the status surface will include durable stage text and message count, with no standalone live activity timeline, repeated provider run cards, looping hero animation, or guessed percentage. The page keeps existing candidate information visible underneath. Navigation cannot produce a cancellation error; on return, the durable status refreshes.

Alternative considered: retain a detailed per-provider timeline. Rejected because it adds operational noise while providing no routine decision for the person to make.

### 5. Preserve progressive disclosure and privacy safeguards

The secondary routes will reuse the existing privacy-safe models. Scan details describe results in a bounded, non-verbatim manner; settings explain read-only access and controls. The implementation must not turn hidden evidence into a default inbox feed merely to make the page feel populated.

## Risks / Trade-offs

- [A calm page may feel like the feature is inactive] → Explicitly state active monitoring and last checked time when that data is available.
- [People may still need manual diagnosis] → Keep Scan details and settings reachable from a predictable overflow menu.
- [A failure can become too hidden after controls move] → Surface a direct recovery action in the status state and deep-link into the relevant settings action.
- [Candidate lists can still become long] → Keep review cards compact and use progressive disclosure for detail/editing.
- [Existing dashboard work overlaps this change] → Reuse its state and models; replace only the landing layout to avoid duplicate backend or data-model work.

## Migration Plan

1. Replace only the Inbox Intelligence presentation hierarchy; retain all existing backend calls and review sheets.
2. Add an Inbox settings/detail route and move the existing secondary controls into it without changing their behavior.
3. Verify each durable state, including leaving while scanning, provider recovery, no-inbox connection, and direct settings actions.
4. Roll back by restoring the current view composition; scan state, connections, alerts, and evidence remain intact because no schema migration is required.

## Open Questions

- Whether Scan details should be a sheet from the overflow menu or a full navigation route. The implementation can select the platform-appropriate option while preserving progressive disclosure.
- Whether to show every pending candidate on the landing page or cap the visible set with a “Review all” route if high-volume scans make the page unwieldy.
