## Why

Renewa currently exposes upcoming payments as a month-grouped list, which makes it difficult to see concentration of charges and to plan around specific renewal deadlines. A dedicated interactive calendar makes upcoming commitments scannable by date while keeping payment details close at hand.

## What Changes

- Replace the calendar destination's agenda-first layout with a navigable monthly deadline calendar.
- Mark active subscription renewal dates in the visible month and support several deadlines on one day.
- Let people select a date to view its scheduled subscription payments, amounts, and an intentional empty state.
- Project recurring deadlines from each subscription's next renewal date and billing cycle for the displayed month without changing stored subscription data.
- Retain a concise near-term payment summary and accessibility-friendly descriptions of calendar dates.

## Capabilities

### New Capabilities

- `subscription-deadline-calendar`: Monthly, interactive presentation of active subscription renewal deadlines and their selected-date details.

### Modified Capabilities

- None.

## Impact

- Affects `Renewa/PaymentCalendarView.swift` and supporting calendar/date utilities or tests.
- Reuses the existing `Subscription.nextRenewalDate`, `BillingCycle`, active-status filtering, currency conversion, brand icon, theme, and Heroicon systems.
- Requires no Supabase schema, API, or Edge Function change for the initial release.
