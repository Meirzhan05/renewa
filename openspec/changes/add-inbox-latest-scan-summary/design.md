## Context

`simplify-inbox-intelligence-ui` intentionally removed the oversized health dashboard, run timeline, metrics grid, and permanent history from the Inbox Intelligence landing page. The resulting healthy state is calm but visually sparse: it states that monitoring is active without showing enough recent, privacy-safe evidence of the assistant’s work. The existing scan-status response already exposes the provider connection summaries, latest completion time, checked-message count, likely-billing count, pending candidates, and a secondary Scan details route.

## Goals / Non-Goals

**Goals:**

- Add enough concrete, recent information for a completed scan to feel credible and useful.
- Preserve a clear hierarchy: current decision first, proof of the latest work second, investigation only on request.
- Reuse durable server status and avoid inventing metrics or aggregating unsupported time periods.
- Keep the no-action state compact and calm.

**Non-Goals:**

- Restoring a dashboard, per-provider timeline, lifecycle grid, permanent evidence feed, or a dominant manual scan button.
- Changing scan scheduling, provider APIs, extraction behavior, monitoring, notifications, or privacy policy.
- Showing raw email text, complete addresses, internal model output, or scanning progress percentages.

## Decisions

### 1. Add one Latest check card below the current state

When at least one connected inbox has a completed check, the landing page will show a single compact Latest check card after the primary state card and before any reviewable candidates. It summarizes the relevant provider label, relative completion time, optional trustworthy counts, and a human-readable outcome such as “No new subscription changes need review.”

The card is not a feed: it represents the most recent durable scan outcome, not every provider job or historical event. It will not appear in the no-inbox state or replace active-scan feedback.

Alternative considered: expand the primary state card with all information. Rejected because it would make the answer and proof indistinguishable, recreating the oversized hero problem.

### 2. Treat metrics as supporting evidence, not performance telemetry

The card may show checked-message and likely-billing counts only when the durable response identifies meaningful completed work. They are labelled as the latest check, never as daily/monthly totals, and are omitted rather than displaying a misleading zero when no trustworthy count exists. Pending-review count remains represented by the primary review section, not repeated as a metric.

Alternative considered: show a fixed three-column metric grid. Rejected because it produces empty/zero-heavy chrome for incremental checks and competes with the review queue.

### 3. Make Scan details the only path to expanded history

The Latest check card includes a low-emphasis Scan details disclosure. It routes to the existing privacy-minimized details surface containing non-actionable outcomes and safe history. It does not expand in place or reveal historical lifecycle cards on the landing screen.

Alternative considered: show the latest three scan events below the card. Rejected because it creates a timeline and begins to crowd the healthy state again.

### 4. Use the header to orient rather than repeat status

The subtitle will describe the page as subscription activity from connected inboxes. The current state card alone communicates monitoring status, which prevents repeated “we watch” language.

## Risks / Trade-offs

- [A completed incremental check can have no useful count] → Retain provider, time, and outcome; omit unavailable metrics rather than showing a fabricated number.
- [Multiple inboxes can make a provider label ambiguous] → Use a compact aggregate label such as “2 connected inboxes” and keep individual accounts in Inbox settings.
- [More visible activity can expose sensitive details] → Use only existing redacted, aggregate fields and keep full history behind Scan details.
- [The landing page could drift back into a dashboard] → Limit it to one compact latest-check card and no metrics grid or timeline.

## Migration Plan

1. Extend only the SwiftUI presentation derived from the current scan-status model.
2. Test complete, no-action, review-ready, scanning, no-inbox, and multi-inbox states.
3. Validate dynamic-type and VoiceOver layout around optional metric rows.
4. Roll back by removing the Latest check card; scan status and secondary details remain unchanged.

## Open Questions

- Whether the likely-billing count should say “likely billing” or a friendlier “billing messages considered”; implementation can select the clearest privacy-safe copy after visual review.
