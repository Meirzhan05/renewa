## ADDED Requirements

### Requirement: Review before subscription mutation
The system SHALL require user confirmation before applying every newly detected addition, cancellation, reactivation, renewal update, or material price change introduced by this capability.

#### Scenario: Candidate is awaiting review
- **WHEN** structured extraction and deterministic validation succeed
- **THEN** the candidate appears as pending and the underlying subscription remains unchanged

#### Scenario: User confirms an addition
- **WHEN** the owner confirms a valid new-subscription candidate
- **THEN** the system creates one subscription and marks the candidate and detected event applied

#### Scenario: User confirms an existing-subscription change
- **WHEN** the owner confirms a candidate with one valid owned match
- **THEN** the system applies the validated fields once and records the applied subscription identifier

### Requirement: Editable candidate facts
The system SHALL allow the user to correct merchant name, positive amount, ISO currency, billing cycle, renewal date, and category before confirming an addition or update.

#### Scenario: User corrects an extracted amount
- **WHEN** the owner edits an amount to a valid positive value and confirms
- **THEN** the corrected amount is used and the correction remains distinguishable from the original extracted candidate

#### Scenario: User enters invalid facts
- **WHEN** edited fields fail deterministic validation
- **THEN** confirmation is rejected and no subscription is changed

### Requirement: Safe rejection and idempotency
The system SHALL allow the owner to ignore a pending candidate and SHALL make repeated confirm or ignore requests idempotent.

#### Scenario: User ignores a candidate
- **WHEN** the owner ignores a pending candidate
- **THEN** its review state changes to ignored and no subscription is changed

#### Scenario: Confirmation is repeated
- **WHEN** the same confirmation request is retried
- **THEN** the system returns the previously applied outcome without creating or applying a duplicate

### Requirement: User-owned review access
The system MUST expose, confirm, edit, and ignore candidates only for the authenticated owner.

#### Scenario: User references another user's candidate
- **WHEN** an authenticated user submits a candidate identifier owned by another user
- **THEN** the system returns not found or forbidden and performs no mutation

