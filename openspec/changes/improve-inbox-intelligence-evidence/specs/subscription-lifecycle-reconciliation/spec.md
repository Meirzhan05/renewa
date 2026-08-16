## ADDED Requirements

### Requirement: Lifecycle from resolved evidence only
The system SHALL determine a merchant's current, ended, or uncertain lifecycle from its resolved evidence bundle in source-received order. Ambiguous or unresolved events MUST NOT create an add, update, or cancellation proposal.

#### Scenario: Identity ambiguity prevents lifecycle action
- **WHEN** a billing event has ambiguous merchant identity
- **THEN** the system records the ambiguity and does not use that event to create an actionable lifecycle outcome

#### Scenario: A bundle contains later current evidence
- **WHEN** a resolved bundle contains a receipt or renewal after a previously recorded cancellation event
- **THEN** the system recomputes lifecycle from the ordered bundle and resolves stale cancellation candidates when current evidence is supported
