## ADDED Requirements

### Requirement: Automatic scans preserve terminal-only notification behavior
The system SHALL not send a user notification for each mailbox provider event, scan start, or intermediate scan stage. It SHALL evaluate the existing opt-in terminal outcome policy once an automatic incremental batch reaches a terminal state.

#### Scenario: Provider events produce no reviewable discovery
- **WHEN** one or more provider events result in a successful automatic batch with no reviewable candidate
- **THEN** the system SHALL send no notification unless the person explicitly enabled the existing no-candidate outcome notification

#### Scenario: An automatic scan finds reviewable evidence
- **WHEN** a provider-triggered automatic batch reaches a terminal state with a reviewable subscription candidate
- **THEN** the system SHALL use the opted-in terminal notification policy and route the person to Inbox Intelligence
