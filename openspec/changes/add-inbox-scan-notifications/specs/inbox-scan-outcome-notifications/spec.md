## ADDED Requirements

### Requirement: Inbox scan outcome consent and device registration
The system SHALL request Inbox Intelligence notification consent only in context after a user has connected an inbox or explicitly enabled Inbox Intelligence alerts. It SHALL register the current iOS APNs device token only for the authenticated owner and SHALL support multiple active installations per owner. Notification denial or token-registration failure MUST NOT prevent scanning or reviewing discoveries.

#### Scenario: User enables Inbox Intelligence alerts after connecting an inbox
- **WHEN** a user enables Inbox Intelligence alerts and grants iOS notification permission
- **THEN** the system stores an enabled installation for the authenticated user and enables inbox scan outcome alerts for that user

#### Scenario: User declines notification permission
- **WHEN** a user declines iOS notification permission
- **THEN** inbox scanning and candidate review remain available and no enabled installation is created for the device

### Requirement: Terminal scan outcome creation
The system SHALL create at most one durable outcome event for each completed inbox scan batch and outcome type. It SHALL classify the batch as `review_ready` only when it creates new pending review-eligible candidates, `no_new_discoveries` when it completes without such candidates, or `reconnect_required` when a connected inbox needs renewed authorization. It MUST NOT create outcome events for individual source emails, extracted events, ambiguous evidence, or intermediate scan stages.

#### Scenario: Completed scan finds candidates to review
- **WHEN** all jobs in a scan batch are terminal and the batch created two pending review-eligible candidates
- **THEN** the system creates one `review_ready` outcome event with a count of two

#### Scenario: Completed scan finds nothing actionable
- **WHEN** all jobs in a scan batch complete without new pending review-eligible candidates
- **THEN** the system creates one `no_new_discoveries` outcome event for the batch

#### Scenario: Batch finalization retries
- **WHEN** scan batch finalization runs more than once for the same completed batch and outcome
- **THEN** the system retains one deduplicated outcome event rather than sending duplicate alerts

### Requirement: Privacy-minimized outcome delivery
The system SHALL deliver an enabled user one terminal Inbox Intelligence outcome alert per eligible batch outcome, subject to device-level deduplication and delivery retry policy. The payload MUST contain only a localized outcome summary, optional aggregate count, a versioned Inbox Intelligence route, and a batch reference. It MUST NOT contain raw email content, evidence excerpts, model output, OAuth data, credentials, or subscription field values.

#### Scenario: No-discovery outcome is delivered
- **WHEN** an enabled user has an eligible device and a completed scan produces `no_new_discoveries`
- **THEN** the user receives an alert stating that the inbox scan completed with no new subscriptions found

#### Scenario: APNs rejects a stale device token
- **WHEN** APNs identifies a registered device token as invalid or unregistered
- **THEN** the system disables that installation and does not retry delivery to that token until it is registered again

### Requirement: Notification routing and current-state fetch
The iOS app SHALL route an Inbox Intelligence outcome notification tap to Inbox Intelligence and fetch the current authenticated scan state before displaying results. It MUST safely show the Inbox Intelligence overview when the referenced batch is stale, deleted, or no longer available to the current user.

#### Scenario: User opens a discovery notification
- **WHEN** a user taps a `review_ready` notification
- **THEN** the app opens Inbox Intelligence and retrieves the current pending-candidate state for that user

#### Scenario: Notification refers to cleared history
- **WHEN** a user taps an outcome notification after clearing scan history
- **THEN** the app opens Inbox Intelligence without exposing stale candidate data or an authorization error
