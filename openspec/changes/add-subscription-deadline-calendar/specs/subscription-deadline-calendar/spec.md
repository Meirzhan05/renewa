## ADDED Requirements

### Requirement: Monthly subscription deadline calendar
The system SHALL present the existing calendar destination as a navigable month view containing a seven-column calendar grid. The grid SHALL show each day in the focused month, visually distinguish today, and indicate days on which active subscription deadlines occur.

#### Scenario: Current month opens
- **WHEN** a person opens the subscription calendar
- **THEN** the system displays the current month, all of its days, and a visible today treatment

#### Scenario: A single deadline is present
- **WHEN** one active subscription has a projected renewal on a displayed day
- **THEN** the system displays a subtle deadline indicator on that day

#### Scenario: Several deadlines share a day
- **WHEN** two or more active subscriptions have projected renewals on the same displayed day
- **THEN** the system displays an indicator that communicates the number of deadlines without rendering duplicate decorative dots

### Requirement: Month navigation and date selection
The system SHALL provide previous-month, next-month, and Today controls. The system SHALL let a person select any day in the focused month and SHALL show the selected day with a distinct, non-ambiguous state.

#### Scenario: Navigate to another month
- **WHEN** a person activates the next- or previous-month control
- **THEN** the system displays the requested month and its projected active-subscription deadlines

#### Scenario: Return to today
- **WHEN** a person activates Today after navigating away from the current month
- **THEN** the system returns to the current month and selects the current day

#### Scenario: Select a date
- **WHEN** a person selects an in-month calendar day
- **THEN** the system updates the selected-date details to that day

### Requirement: Selected-date payment details
The system SHALL show a selected-date section containing all active subscription deadlines projected for the selected day. Each payment row SHALL include its brand presentation, subscription name, renewal context, and original amount; it SHALL show a converted amount when the existing currency conversion is available.

#### Scenario: Selected date has payments
- **WHEN** the selected date has one or more projected deadlines
- **THEN** the system lists every corresponding subscription payment and displays a date-level total when all amounts can be converted to the default currency

#### Scenario: Selected date has no payments
- **WHEN** the selected date has no projected deadlines
- **THEN** the system presents an explicit empty state stating that no subscription payment is due that day

#### Scenario: A conversion is unavailable
- **WHEN** at least one selected-date payment cannot be converted to the default currency
- **THEN** the system retains each original amount and does not display a misleading converted date-level total

### Requirement: Recurring deadline projection
The system SHALL derive deadlines for the focused month from active subscriptions' `nextRenewalDate` and billing cycle without writing projected occurrences to persistent storage. The recurrence calculation SHALL retain the stored renewal date as its anchor and SHALL not drift after a shortened calendar month.

#### Scenario: Monthly renewal crosses a shortened month
- **WHEN** a monthly subscription anchored on the 31st is projected across February into a month that contains the 31st
- **THEN** the later occurrence uses the 31st when that day exists rather than permanently adopting February's shorter date

#### Scenario: Non-monthly billing cycle
- **WHEN** a weekly, quarterly, or yearly active subscription has an occurrence in the focused month
- **THEN** the system displays that projected occurrence on its calendar day

#### Scenario: Inactive subscription
- **WHEN** a subscription is canceled or paused
- **THEN** the system does not project a deadline for it

### Requirement: Accessible and motion-safe calendar interaction
The system SHALL expose each in-month date as an accessible control with its full date, deadline count, and due-total availability when applicable. Calendar selection and month navigation SHALL respect the user's Reduce Motion preference.

#### Scenario: Screen reader reads a due date
- **WHEN** a screen reader focuses a day with deadlines
- **THEN** it announces the full date and number of subscription payments due, without announcing decorative indicators separately

#### Scenario: Reduce Motion is enabled
- **WHEN** a person with Reduce Motion enabled changes the selected date or focused month
- **THEN** the system uses non-transform or minimal transition behavior while preserving the updated calendar and details
