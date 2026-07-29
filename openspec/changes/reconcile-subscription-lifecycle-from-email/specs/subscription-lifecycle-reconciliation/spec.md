## ADDED Requirements

### Requirement: Lifecycle reconciliation from merchant-local evidence
The system SHALL retain a provider source-received timestamp for each detected billing event and SHALL deterministically reduce all events owned by one user and canonical merchant key into `current`, `ended`, or `uncertain` lifecycle evidence before creating an actionable discovery candidate.

#### Scenario: Later cancellation supersedes an earlier receipt
- **WHEN** a merchant has a paid recurring receipt followed by a later valid cancellation event
- **THEN** the lifecycle result SHALL be ended and the receipt SHALL not produce an add or update candidate

#### Scenario: Future renewal supports a current subscription
- **WHEN** a paid recurring event has a future renewal date and no later ending event
- **THEN** the lifecycle result SHALL be current and may support a review-first add or update candidate

#### Scenario: Historical receipt has no current evidence
- **WHEN** a paid recurring event has no future renewal date and its derived renewal date is before today
- **THEN** the lifecycle result SHALL be uncertain and SHALL not create an add or update candidate

### Requirement: Conservative lifecycle inference
The system MUST NOT infer an ended subscription solely from the absence of a later message. Trials, incomplete financial facts, past-due projected renewals, and conflicting evidence SHALL remain uncertain unless explicit later ending evidence exists.

#### Scenario: No cancellation email is found
- **WHEN** a merchant has an old receipt but no later cancellation event
- **THEN** the system SHALL classify it as uncertain rather than canceled

#### Scenario: Trial without paid recurring evidence
- **WHEN** a merchant has only a trial-started or trial-ending event
- **THEN** the system SHALL not create a paid subscription add candidate

### Requirement: Stale candidate reconciliation
The system SHALL re-evaluate lifecycle evidence when new merchant events arrive and before confirming a candidate. It SHALL resolve pending add/update candidates that are superseded by ended or uncertain lifecycle evidence without mutating a subscription.

#### Scenario: Cancellation arrives after an add candidate
- **WHEN** a pending add candidate is followed by a later cancellation event for the same merchant
- **THEN** the add candidate SHALL be system-resolved with a non-sensitive reason and SHALL not be confirmable

#### Scenario: Candidate is confirmed after later evidence
- **WHEN** a person attempts to confirm a pending candidate after later lifecycle evidence changed it to ended or uncertain
- **THEN** the system SHALL reject the stale confirmation and return the current resolution reason
