## ADDED Requirements

### Requirement: Explainable system-resolved candidates
The system SHALL retain a non-sensitive system resolution reason when lifecycle reconciliation withdraws a pending candidate, and it SHALL prevent a withdrawn candidate from being applied.

#### Scenario: Candidate was superseded by later ending evidence
- **WHEN** lifecycle reconciliation resolves a pending candidate because of a later ending event
- **THEN** the candidate SHALL no longer be actionable and SHALL retain a reason that does not include raw email content

### Requirement: Candidate-level unused-service feedback
The review interface SHALL offer “I don’t use this” for pending non-cancellation candidates and SHALL explain that the choice prevents future discovery suggestions for that merchant without canceling an existing subscription.

#### Scenario: Person suppresses a candidate from the review interface
- **WHEN** a person uses the unused-service control
- **THEN** the candidate SHALL leave the pending queue and the interface SHALL confirm that no subscription was changed
