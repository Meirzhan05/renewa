## ADDED Requirements

### Requirement: Merchant-level discovery suppression
The system SHALL allow the owner of a pending non-cancellation discovery candidate to suppress future discovery proposals for its canonical merchant. Suppression SHALL be scoped to that user and SHALL be reversible.

#### Scenario: Person no longer uses a suggested merchant
- **WHEN** a person selects “I don’t use this” for a pending add or update candidate
- **THEN** the system SHALL store a user-owned suppression, resolve pending non-cancellation candidates for that merchant, and leave subscription rows unchanged

#### Scenario: Later active evidence is scanned for a suppressed merchant
- **WHEN** a new event supports a current lifecycle for a suppressed merchant
- **THEN** the system SHALL retain the immutable event but SHALL not create a new actionable candidate

#### Scenario: Person reverses suppression
- **WHEN** a person removes a merchant suppression
- **THEN** future current lifecycle evidence for that merchant SHALL be eligible for normal review-first discovery

### Requirement: Suppression does not hide an existing subscription cancellation
The system SHALL not use merchant suppression to automatically change an existing subscription or to hide an explicit cancellation proposal for one matched active subscription.

#### Scenario: Suppressed merchant has a tracked active subscription
- **WHEN** explicit ending evidence matches one active subscription owned by the person
- **THEN** the system SHALL retain a review-required cancellation candidate
