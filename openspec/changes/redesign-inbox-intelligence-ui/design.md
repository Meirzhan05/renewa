## Context

Inbox Intelligence currently combines connection controls, a scan hero, scan progress, and review cards in one screen. A completed scan without a pending candidate is visually close to an empty or failed state, even when the scanner processed substantial mailbox evidence and deliberately withheld non-actionable results. The existing discovery pipeline already exposes durable run status, connection summaries, candidates, validation counts, lifecycle outcomes, and privacy-minimized evidence; the redesign should make those states legible without exposing mail content or giving the scanner mutation authority.

## Goals / Non-Goals

**Goals:**

- Make the screen answer connection health, current scan state, last meaningful outcome, and the user's next action at a glance.
- Separate reviewable subscription changes from safe/non-actionable evidence.
- Preserve accurate progress when a provider cannot give a trustworthy total.
- Make background behavior and recoverable errors explicit.
- Replace persistent skeletons with state-specific content and accessible status text.

**Non-Goals:**

- Changing OAuth scopes, the mail-fetching algorithm, DeepSeek extraction, lifecycle policy, or automatic-monitor schedule.
- Showing raw email bodies, sender addresses, raw model output, or hidden policy heuristics.
- Allowing the scanner to create, update, or cancel subscriptions without a confirmation.
- Building an app-wide notification center; this change is limited to Inbox Intelligence presentation.

## Decisions

### 1. Use a scan-health dashboard as the landing surface

The landing screen will be composed in priority order: scan-health summary, reviewable actions, learning/history summary, then connection and preferences. This replaces a static hero whose copy does not reflect the current scan state.

The summary expresses a mutually exclusive state: no inbox, connecting/first scan, actively scanning, completed with actions, completed without actions, or needs attention. It includes a provider-safe status label, last completion time when available, checked-message count, likely-billing count, and the number of reviewable changes. It uses text such as “monitored daily” only when automatic monitoring is enabled for the connection.

Alternative considered: retain the existing hero and add more small cards below it. Rejected because the state remains visually secondary and the user still has to infer the scan outcome.

### 2. Report durable work rather than invented percentages

Active scans will show the current durable stage (for example, finding likely billing mail or checking evidence) and messages checked. The experience will not show a percentage unless a provider supplies a reliable total. It will explain that navigation is safe and that the server-side scan continues in the background.

Alternative considered: derive a percentage from historical page size or messages already checked. Rejected because the initial Gmail scan and cursor fallbacks do not provide a stable denominator.

### 3. Divide results into “Actions for you” and “What we learned”

Only pending, reviewable candidates appear in the primary action section. A completed scan with no candidates uses a positive no-action state, not an empty list. A secondary learning summary groups privacy-minimized aggregate outcomes such as ended subscriptions, evidence requiring more confirmation, held-back ambiguities, and validation skips. It never presents those entries as active subscriptions.

The detail route expands an item into event type, merchant label, received date, non-verbatim explanation, and lifecycle/result reason. It deliberately omits raw email text and full addresses. Detailed evidence presentation should reuse the evidence structures from `improve-inbox-intelligence-evidence` rather than invent a second evidence model.

Alternative considered: show every model extraction in the landing feed. Rejected because it creates noise, overstates uncertain data, and weakens the review-first promise.

### 4. Treat loading and errors as local, recoverable states

Skeletons are reserved for the first unresolved dashboard request and are bounded to the content that is actually loading. Once status is known, the summary remains visible while an operation is underway. Connection, scan, and review failures appear in the affected card with a human-readable message and one relevant recovery action; cancellation due to navigation is not surfaced as an error.

Alternative considered: retain a page-wide loading state and global alerts. Rejected because it hides usable content and led to misleading “cancelled” alerts during tab changes.

### 5. Extend the scan read model only where the UI lacks safe summary data

The client should derive presentation from the server's durable scan/run and candidate data. If the existing response cannot distinguish non-actionable lifecycle outcomes or provide an item’s privacy-minimized evidence summary, add a user-scoped read-only response field or endpoint. The server remains the authority for counts, lifecycle state, and privacy filtering; the client must not infer an active subscription from an event.

### Implementation read-model audit

The existing `email-scan` status response already provides durable aggregate stage, checked-message, likely-billing, validation-failure, pending-candidate, connection-health, and candidate evidence data. It did not expose automatic-monitoring state, aggregate ended/uncertain lifecycle outcomes, compact non-actionable evidence items, or the run-level withheld-ambiguity total. The implementation adds those fields to the authenticated Function response only; its queries remain scoped by `user_id`, and the new item shape contains only merchant label, event type, received date, lifecycle outcome, and a bounded explanation.

## Risks / Trade-offs

- [Historic scans can contain many old events] → Show compact counts by default and make detail progressively disclosed.
- [A “no action” summary can be mistaken for a clean inbox] → State that billing history may have been found but no safe review is needed.
- [Backend data may not yet expose every aggregate] → Deliver the dashboard against current fields first, then add only the minimal read model needed for real values; never fabricate counts.
- [Concurrent scan completion changes the screen] → Drive state from refreshed batch status and animate only local transitions.
- [Evidence can expose sensitive information] → Enforce redaction and bounded descriptions server-side; add accessibility labels with the same minimized text.
- [Related evidence work is in progress] → Reuse its candidate/evidence entities and avoid duplicate migrations or conflicting routes.

## Migration Plan

1. Introduce the new dashboard behind the existing Inbox Intelligence tab, preserving manual scan, connection, review, disconnect, and notification controls.
2. Add or extend only read-only, user-scoped scan summary data required for the non-actionable history section.
3. Verify each state with seeded/local scan data and existing scan flows, including leaving the tab while work continues.
4. Roll back by restoring the previous screen composition; scan jobs, evidence, OAuth connections, and subscriptions remain untouched.

## Open Questions

- Should detailed non-actionable evidence be available as a full history screen immediately, or limited to the most recent completed scan for the first release?
- Which aggregate labels are most helpful without creating concern: “ended,” “needs more evidence,” “held back,” or a simpler user-facing vocabulary?
