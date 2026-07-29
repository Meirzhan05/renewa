## ADDED Requirements

### Requirement: Asynchronous multi-connection scanning
The system SHALL create a durable scan job for every connected inbox owned by the authenticated user and SHALL return a scan identifier without waiting for mailbox retrieval or AI extraction to complete.

#### Scenario: User starts a scan with multiple inboxes
- **WHEN** an authenticated user starts discovery with two connected inboxes
- **THEN** the system creates two user-owned jobs under one scan identifier and reports aggregate progress

#### Scenario: Worker terminates
- **WHEN** a scan worker stops before a retryable job completes
- **THEN** the persisted job remains resumable without duplicating detected events

### Requirement: Incremental provider synchronization
The system SHALL perform a bounded paginated bootstrap for a new connection and SHALL use a provider-specific cursor for later scans. A cursor MUST advance only after its retrieved messages are processed successfully.

#### Scenario: Gmail connection was scanned previously
- **WHEN** a valid Gmail history cursor exists
- **THEN** the system retrieves newly added messages from Gmail history rather than repeating the bootstrap window

#### Scenario: Microsoft connection was scanned previously
- **WHEN** a valid Microsoft delta link exists
- **THEN** the system follows the opaque delta link and persists the next completed delta link

#### Scenario: Provider cursor expired
- **WHEN** a provider rejects a stored incremental cursor
- **THEN** the system performs a bounded fallback scan and records the replacement cursor

### Requirement: Privacy-minimized candidate retrieval
The system SHALL inspect bounded metadata or snippets before retrieving full message content, SHALL retrieve full content only for likely billing candidates, and MUST NOT persist raw email bodies.

#### Scenario: Message has no billing signal
- **WHEN** a message does not satisfy candidate signals
- **THEN** the system does not retrieve or send its full body to the AI provider

#### Scenario: Candidate is processed
- **WHEN** a likely billing message is processed
- **THEN** sanitized and truncated content exists only for the extraction request and is not stored in Renewa tables

### Requirement: Constrained structured extraction
The system SHALL use one constrained extractor per message or bounded merchant-local batch, SHALL allow abstention, and SHALL reject output that fails the versioned runtime schema. The extractor MUST NOT receive tools or authority to mutate subscriptions.

#### Scenario: Valid billing event is returned
- **WHEN** the model returns a schema-valid event tied to the submitted message
- **THEN** the system persists a detected event and reviewable candidate without changing a subscription

#### Scenario: Model output is malformed
- **WHEN** output contains an invalid amount, currency, date, enum, or message identifier
- **THEN** the system records a non-sensitive validation failure and does not create an actionable candidate

#### Scenario: Model abstains
- **WHEN** the message does not contain a concrete subscription event
- **THEN** the system completes message processing without a candidate

### Requirement: Deterministic reconciliation
The system SHALL derive provider-independent merchant keys and SHALL match candidates to subscriptions using server-owned deterministic rules. The model MUST NOT select or invent a subscription identifier.

#### Scenario: Exactly one existing subscription matches
- **WHEN** canonical identity, reviewed aliases, or normalized historical identity produces one owned subscription match
- **THEN** the candidate references that subscription as a proposed update

#### Scenario: Match is ambiguous
- **WHEN** more than one owned subscription plausibly matches
- **THEN** the candidate remains unresolved and requires user review without changing any match

### Requirement: Observable partial failure
The system SHALL persist scan stage, bounded counts, per-connection completion, and redacted errors, and SHALL distinguish complete, partial, and failed aggregate outcomes.

#### Scenario: One of two providers fails
- **WHEN** one connection completes and another fails
- **THEN** the aggregate scan reports a partial result and preserves candidates from the successful connection

