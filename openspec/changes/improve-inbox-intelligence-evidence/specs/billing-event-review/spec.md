## ADDED Requirements

### Requirement: Evidence-aware candidate review
The system SHALL show the user the privacy-minimized merchant evidence supporting each actionable candidate, including event type, merchant label, received date, and a non-verbatim explanation. It MUST NOT show a raw email body in the review experience.

#### Scenario: A candidate has multiple supporting events
- **WHEN** a candidate is backed by more than one billing event
- **THEN** the review UI presents a compact chronological evidence summary and the reason the proposed action is eligible

### Requirement: Structured correction feedback
The system SHALL allow a user who confirms or ignores a candidate to provide an optional standardized correction reason. A valid confirmed correction MAY establish a reviewed merchant alias only after deterministic validation confirms the alias is unambiguous.

#### Scenario: A user corrects a merchant alias
- **WHEN** a user confirms a candidate with a valid, unambiguous merchant correction
- **THEN** the system applies the reviewed change and records a reviewed alias for future identity resolution

#### Scenario: A user supplies no correction reason
- **WHEN** a user completes a review without selecting a reason
- **THEN** the system completes the requested review action and records no free-form feedback text
