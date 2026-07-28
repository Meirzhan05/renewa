## 1. Calendar data projection

- [ ] 1.1 Add a pure, testable deadline projection utility that derives active-subscription occurrences for one focused month from `nextRenewalDate` and `BillingCycle`.
- [ ] 1.2 Preserve anchor-based recurrence calculations for weekly, monthly, quarterly, and yearly subscriptions, including shortened-month behavior.
- [ ] 1.3 Group projected occurrences by local start-of-day and expose selected-day subscriptions plus safely convertible aggregate totals.

## 2. Monthly calendar experience

- [ ] 2.1 Replace the agenda-first `PaymentCalendarView` layout with a focused-month header, previous/next controls, Today action, weekday header, and seven-column date grid.
- [ ] 2.2 Add today, selected-date, single-deadline, and multiple-deadline visual states using existing Renewa theme and Heroicon primitives.
- [ ] 2.3 Add a selected-date payment section with brand rows, original/converted amounts, date-level total behavior, and an explicit no-payment state.
- [ ] 2.4 Preserve the 30-day summary and apply accessible labels, hints, and Reduce Motion-safe state transitions to calendar controls and date details.

## 3. Verification and documentation

- [ ] 3.1 Add XCTest coverage for recurrence projection, month-end anchoring, multi-payment grouping, and exclusion of canceled or paused subscriptions.
- [ ] 3.2 Manually verify current-month, previous/next, Today, empty day, multi-deadline, unavailable-conversion, VoiceOver, and Reduce Motion behavior in the simulator.
- [ ] 3.3 Run the documented simulator and unsigned device builds, update `todo.md`, and record any manual verification notes before completion.
