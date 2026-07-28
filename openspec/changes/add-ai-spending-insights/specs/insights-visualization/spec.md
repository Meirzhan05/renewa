## ADDED Requirements

### Requirement: Category spending visualization
The Insights screen SHALL display a category-composition graph from the user's active subscription monthly commitments, with a text-accessible label and amount for every represented category.

#### Scenario: Categories are available
- **WHEN** the user has active subscriptions with convertible monthly costs
- **THEN** Insights SHALL render a category graph whose values match the deterministic category totals

#### Scenario: No category data is available
- **WHEN** the user has no convertible active subscription costs
- **THEN** Insights SHALL show an explanatory empty state instead of an empty graph

### Requirement: Upcoming renewal timeline
The Insights screen SHALL display renewals due in the next 30 calendar days as a chronological timeline with subscription name, renewal date, and displayable amount.

#### Scenario: Renewals occur in the next 30 days
- **WHEN** active subscriptions have renewal dates within the next 30 days
- **THEN** Insights SHALL render each qualifying renewal in chronological order

#### Scenario: No upcoming renewals
- **WHEN** no active subscription renews within the next 30 days
- **THEN** Insights SHALL show an explanatory no-upcoming-renewals state

### Requirement: Historical spending trend visualization
The Insights screen SHALL display a monthly commitment trend using persisted usable snapshots and SHALL identify the available time range and display currency.

#### Scenario: Trend history is available
- **WHEN** at least two usable snapshots exist
- **THEN** Insights SHALL render a trend graph using only those dated snapshot values

#### Scenario: Reduced motion is enabled
- **WHEN** the user enables Reduce Motion
- **THEN** chart appearance and data updates SHALL not use nonessential animated transitions
