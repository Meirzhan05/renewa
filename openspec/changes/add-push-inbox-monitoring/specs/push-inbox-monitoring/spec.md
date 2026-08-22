## ADDED Requirements

### Requirement: Verified provider mailbox events schedule incremental monitoring
The system SHALL accept Gmail and Microsoft mailbox events only through server-owned provider integrations, verify that each event originated from the configured provider integration, map it to an owned connected inbox, and schedule incremental processing without requiring the iOS app to be active.

#### Scenario: Verified Gmail event arrives for a connected inbox
- **WHEN** a valid Gmail provider event identifies an actively monitored connected inbox
- **THEN** the system SHALL enqueue that inbox for a debounced incremental scan using its stored Gmail history cursor

#### Scenario: Invalid provider event is received
- **WHEN** an event lacks valid provider verification or cannot be mapped to an actively monitored connection
- **THEN** the system SHALL reject or safely ignore the event without creating a scan or exposing mailbox information

### Requirement: Provider watch lifecycle is maintained server-side
The system SHALL provision monitoring after a connection is authorized, record its health and expiry, renew provider watches before expiry, and stop provider monitoring when the inbox is disconnected or authorization becomes invalid.

#### Scenario: A connected inbox is ready for monitoring
- **WHEN** OAuth connection setup completes for a supported provider
- **THEN** the system SHALL attempt to provision that provider’s server-side monitoring resource and persist the resulting monitoring health

#### Scenario: Monitoring renewal fails because authorization is invalid
- **WHEN** the provider rejects a monitoring renewal because the connection can no longer be authorized
- **THEN** the system SHALL mark the inbox as requiring reconnection, stop claiming that monitoring is active, and preserve the existing connection error flow

### Requirement: Event bursts are coalesced safely
The system SHALL deduplicate provider events and coalesce events for the same inbox within a bounded debounce window into at most one active incremental scan, while ensuring an event received during a scan causes a later cursor check.

#### Scenario: Multiple events arrive during the debounce window
- **WHEN** multiple valid events for one connected inbox arrive before its queued incremental scan starts
- **THEN** the system SHALL create or retain one due scan rather than one scan per event

#### Scenario: A new event arrives while a scan is active
- **WHEN** a valid event for an inbox arrives while that inbox has an active scan
- **THEN** the system SHALL retain a follow-up check that runs after the active scan completes

### Requirement: Incremental event scans preserve the existing safety boundary
The system SHALL use the persisted Gmail history cursor or Microsoft delta cursor to identify changed messages, filter metadata before retrieving full content, and apply the existing review-first extraction and lifecycle policy.

#### Scenario: Event-driven scan finds a likely billing email
- **WHEN** the cursor identifies a newly changed message that passes billing-signal filtering
- **THEN** the system SHALL process it through the existing validation and candidate-review workflow without automatically changing a subscription

#### Scenario: Event-driven scan finds no relevant message
- **WHEN** the cursor identifies changed messages but none pass billing-signal filtering
- **THEN** the system SHALL record a successful check without storing raw message content or creating a review candidate

### Requirement: Scheduled reconciliation remains available
The system SHALL run bounded scheduled reconciliation for monitored connections at least daily and SHALL use it to recover from missed provider events, expired watches, and delayed deliveries.

#### Scenario: A provider event is missed
- **WHEN** daily reconciliation runs for an inbox whose stored cursor has unseen changes
- **THEN** the system SHALL process the changes through the same incremental scan pipeline

### Requirement: Historical discovery favors current billing evidence
The system SHALL limit a first-time mailbox discovery scan to messages received within the last 180 days. If a provider synchronization cursor has expired, the recovery scan SHALL limit retrieval to the last 90 days before storing a new cursor.

#### Scenario: A person connects an existing inbox
- **WHEN** a connected inbox has no stored provider cursor
- **THEN** the system SHALL retrieve only the provider's messages from the preceding 180 days, retaining the bound through every historical page

#### Scenario: A provider cursor cannot be used
- **WHEN** a stored provider cursor has expired or is invalidated
- **THEN** the system SHALL recover using only messages from the preceding 90 days and resume incremental processing from the replacement cursor
