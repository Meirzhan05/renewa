## ADDED Requirements

### Requirement: Lifecycle-aware candidate creation
The system SHALL create add and update candidates only after current lifecycle evidence is established for the merchant. It SHALL retain ended and uncertain findings as non-actionable, privacy-minimized audit evidence.

#### Scenario: Initial historical inbox scan finds an old subscription receipt
- **WHEN** the scan finds a historical receipt whose merchant lifecycle is uncertain or ended
- **THEN** the system SHALL not show it in the actionable subscription review queue

### Requirement: Explicit incremental coverage boundary
The system SHALL document and present inbox discovery as best-effort, read-only, Inbox-focused incremental scanning after the initial bounded bootstrap. It SHALL not imply that absence of a cancellation message proves a service is active or ended.

#### Scenario: User views the discovery privacy boundary
- **WHEN** a person views inbox discovery controls
- **THEN** the product SHALL describe the read-only, best-effort nature of incremental inbox evidence
