## ADDED Requirements

### Requirement: A failed provider request is classified by its HTTP status
When a request to a mail provider fails, the failure SHALL be classified from the response status
rather than from a message fixed at the call site. Authorization failures, rate limiting, provider
outages, and other failures SHALL be distinguishable from one another.

#### Scenario: An expired or revoked credential is an authorization failure
- **WHEN** the provider responds `401` or `403`
- **THEN** the failure is classified as an authorization failure

#### Scenario: Throttling is a rate-limit failure
- **WHEN** the provider responds `429`
- **THEN** the failure is classified as rate limiting, not as an authorization failure

#### Scenario: A provider outage is its own class
- **WHEN** the provider responds with any `5xx` status
- **THEN** the failure is classified as provider unavailability, not as an authorization failure

#### Scenario: An unmapped status is not assumed to be authorization
- **WHEN** the provider responds with a failing status that is none of the above
- **THEN** the failure is classified as a generic provider failure

### Requirement: Only an authorization failure asks the user to reconnect
The instruction to reconnect an inbox SHALL be reserved for failures that reconnecting can actually
fix. A failure classified as rate limiting, provider unavailability, or generic SHALL NOT tell the
user their inbox needs reconnecting.

#### Scenario: A throttled scan does not blame the connection
- **WHEN** a scan page fails because the provider returned `429`
- **THEN** the message describes throttling and does not ask the user to reconnect

#### Scenario: A provider outage does not blame the connection
- **WHEN** a scan page fails because the provider returned `503`
- **THEN** the message describes the provider being unavailable and does not ask the user to
  reconnect

#### Scenario: A revoked token does ask the user to reconnect
- **WHEN** a scan page fails because the provider returned `401`
- **THEN** the message asks the user to reconnect their inbox

#### Scenario: A healthy connection is not marked as needing reconnection
- **WHEN** a page fails for a non-authorization reason
- **THEN** the connection's monitoring health is not set to require reconnection

### Requirement: Classification survives to the user-facing message
The category assigned at the point of failure SHALL determine the user-facing message. A message
SHALL NOT be re-derived by pattern-matching text that a previous stage already wrote.

#### Scenario: A rate limit is not re-classified as authorization by its wording
- **WHEN** a rate-limit failure reaches the user-facing error mapping
- **THEN** it is presented as rate limiting, even though generic inbox-authorization patterns might
  match words in the text

#### Scenario: Raw provider text never reaches the user
- **WHEN** a provider returns a body describing its own internal error
- **THEN** the user sees only the fixed copy for the assigned category, never the provider's text

### Requirement: The failure class is recorded for diagnosis
The recorded error for a failed page SHALL identify the classification, so a later reader can tell a
throttled scan from a disconnected inbox without re-running it.

#### Scenario: A stored page failure names its class
- **WHEN** a page fails and its error is written to the scan job
- **THEN** the stored text identifies the failure class

#### Scenario: The status is not lost
- **WHEN** a provider request fails with a status the system does not specifically handle
- **THEN** the recorded error still distinguishes it from an authorization failure
