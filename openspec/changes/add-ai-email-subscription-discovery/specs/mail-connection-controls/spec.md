## ADDED Requirements

### Requirement: Redacted connection status
The system SHALL present each owned inbox connection's provider, redacted address, last successful synchronization, health, and active scan state without exposing provider credentials or raw scopes to the client.

#### Scenario: User opens inbox intelligence
- **WHEN** the authenticated user has connected mailboxes
- **THEN** the client receives redacted connection summaries and no access or refresh token

### Requirement: Safe inbox disconnect
The system SHALL attempt provider-token revocation, remove the encrypted local credential, and prevent later scans after the owner confirms disconnect.

#### Scenario: Provider revocation succeeds
- **WHEN** the owner disconnects a healthy inbox
- **THEN** remote access is revoked, the encrypted connection is deleted, and pending jobs for it cannot run

#### Scenario: Remote token is already invalid
- **WHEN** provider revocation reports an expired or invalid token
- **THEN** the encrypted local connection is still deleted and the user is informed that Renewa no longer retains access

### Requirement: Scan metadata cleanup
The system SHALL allow an owner to delete unapplied scan jobs and scan diagnostic history without deleting confirmed subscriptions.

#### Scenario: User clears scan history
- **WHEN** the owner requests scan-history cleanup
- **THEN** removable jobs, candidates, runs, and events are deleted according to retention rules while subscriptions remain

