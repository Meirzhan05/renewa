## ADDED Requirements

### Requirement: Monthly commitment snapshots
The system SHALL retain one user-owned monthly subscription-commitment snapshot for each represented source currency, including the period, monthly total, and category totals derived from active subscriptions.

#### Scenario: Scheduled period capture
- **WHEN** the monthly snapshot job runs for a user with active subscriptions
- **THEN** the system SHALL create or update the snapshot for the current period without creating duplicates

#### Scenario: Current-period data becomes available
- **WHEN** a successful subscription mutation or email scan changes the user's active subscriptions
- **THEN** the system SHALL update the current-period snapshot using the resulting active subscription data

### Requirement: Honest historical comparisons
The system SHALL expose only persisted dated snapshots for historical visualizations and MUST NOT reconstruct or interpolate earlier spending totals from current subscriptions.

#### Scenario: Insufficient history
- **WHEN** fewer than two usable monthly snapshots exist
- **THEN** the system SHALL show an insufficient-history state instead of a spending-trend comparison

#### Scenario: Currency conversion is unavailable
- **WHEN** a snapshot cannot be converted to the user's selected display currency
- **THEN** the system SHALL identify that point as unavailable and MUST NOT combine it into a misleading total

