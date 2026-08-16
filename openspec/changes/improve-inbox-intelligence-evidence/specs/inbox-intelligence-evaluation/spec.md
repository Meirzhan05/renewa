## ADDED Requirements

### Requirement: Privacy-minimized discovery evaluation
The system SHALL evaluate discovery behavior against a redacted fixture corpus covering recurring billing, one-time purchases, cancellations, aliases, payment processors, non-English mail, marketing, and adversarial instruction text. Evaluation fixtures MUST NOT contain production mailbox content.

#### Scenario: A fixture is evaluated
- **WHEN** the discovery evaluation suite runs
- **THEN** it reports expected candidate eligibility, identity resolution, lifecycle outcome, and schema-validation results for each fixture

### Requirement: Review-outcome quality records
The system SHALL record a user-owned, privacy-minimized outcome whenever a discovery candidate is confirmed, edited, ignored, suppressed, or applied as a cancellation. The outcome SHALL link to the candidate and supporting evidence and record normalized requested/applied fields plus an optional standardized correction reason.

#### Scenario: A user edits a proposed subscription
- **WHEN** a user confirms a candidate after changing a supported field
- **THEN** the system records the normalized proposed and applied values and marks the outcome as corrected without storing raw email content

#### Scenario: A user ignores a candidate
- **WHEN** a user ignores a discovery candidate
- **THEN** the system records an ignored outcome and leaves every subscription unchanged

### Requirement: Aggregated quality telemetry
The system SHALL make privacy-minimized aggregate telemetry available for extraction, identity resolution, adjudication, lifecycle eligibility, review outcomes, latency, and model cost by prompt/model version. It MUST NOT include raw message bodies, raw model responses, or mailbox addresses.

#### Scenario: A scan completes
- **WHEN** an inbox scan finishes or fails
- **THEN** the system records bounded aggregate stage counts and timing/version metadata for quality analysis
