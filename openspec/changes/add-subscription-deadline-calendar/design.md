## Context

`PaymentCalendarView` currently displays active, future subscriptions as a month-grouped agenda. The subscription model already provides a next renewal date, billing cycle, status, category, price, currency, and brand information; it does not persist every future recurrence. The redesigned screen must make deadline density understandable without introducing a Supabase migration or a new runtime dependency.

## Goals / Non-Goals

**Goals:**

- Provide a navigable, accessible month grid for subscription deadlines.
- Project recurring active-subscription deadlines accurately for the displayed month.
- Make a selected day’s payments and total immediately understandable.
- Preserve Renewa’s existing warm visual system, currency conversion behavior, and Reduce Motion support.

**Non-Goals:**

- Creating device notifications, Apple Calendar events, payment-completion tracking, or a historical payment ledger.
- Editing subscriptions directly from the calendar in the first release.
- Persisting projected occurrences to Supabase.

## Decisions

### Use a month grid with a selected-day agenda

The screen will put a compact 7-column month grid ahead of the existing details, then show a selected-date section below it. A date displays a dot for one deadline and a count badge for several; selecting it reveals the concrete subscription rows and an intentional empty state.

This provides both the scanning benefit of a calendar and the information density of the current agenda. Replacing it with a list alone would preserve the existing problem, while a grid without date details would hide amounts and subscription identity.

### Treat the stored renewal date as a recurring-series anchor

Only active subscriptions participate. For each visible month, a pure deadline projector will derive occurrences from `nextRenewalDate` and `billingCycle`, grouping them by local calendar day. It will calculate each occurrence as an offset from the stored anchor rather than repeatedly adding to the previous occurrence, preventing month-end drift such as January 31 becoming permanently the 28th.

The projector will return only dates within the displayed month. This keeps memory and date math bounded during month navigation and avoids persisting speculative future records. Canceled and paused subscriptions remain absent, matching the current calendar behavior.

### Make navigation deterministic

The screen opens on the current month with today selected. Previous and next controls change the focused month; a Today action returns to the current month and selects today. Changing the month selects its first in-month day unless the current selected date also belongs to the new month. Dates from adjacent months are visible for grid alignment but are non-interactive.

### Reuse existing payment and accessibility language

The near-term 30-day summary, converted-amount handling, `SubscriptionBrandIcon`, theme, and Heroicons will be retained. Each day control will expose a VoiceOver label containing its full date, payment count, and displayable due total when available. Decorative dots and badges will not become duplicate accessibility elements.

## Risks / Trade-offs

- [Calendar/date arithmetic can be sensitive to daylight-saving and locale changes] → Normalize comparisons to `Calendar.current.startOfDay` and use `Calendar` date-component arithmetic; add unit coverage for week, month, quarter, year, and month-end cases.
- [A user may expect canceled subscriptions to remain visible through their final paid period] → Scope the initial behavior to active subscriptions, consistent with the current source data and UI; add explicit end-of-service data before supporting that use case.
- [Several converted amounts may be unavailable] → Show each original amount and omit the aggregate converted total rather than presenting a misleading sum.
- [Dense months can make a grid visually noisy] → Use one subtle indicator for a single deadline and a compact numeric count for multiple, with detail deferred until selection.

## Migration Plan

1. Add the local deadline projection utility and calendar UI behind the existing calendar destination.
2. Verify in the simulator using active subscriptions with empty, single, multiple, recurring, canceled, and paused states.
3. Release as a client-only UI update. No database migration is required.
4. If a regression appears, revert the view change; stored subscription data is unaffected.

## Open Questions

- Whether a later release should let a calendar payment row open the subscription editor.
- Whether reminders should be local notifications, calendar export, or both; this remains a separate capability.
