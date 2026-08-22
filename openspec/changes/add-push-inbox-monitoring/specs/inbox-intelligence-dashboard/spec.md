## ADDED Requirements

### Requirement: Dashboard framing reflects proactive inbox monitoring
The Inbox Intelligence dashboard SHALL frame a healthy connected inbox as continuously monitored by the server and SHALL avoid language that implies a person must manually start each scan to remain protected.

#### Scenario: A healthy monitored inbox has no pending candidates
- **WHEN** a connected inbox has active provider monitoring and no reviewable candidate
- **THEN** the dashboard SHALL state that it is monitoring new inbox activity automatically and distinguish that status from a completed manual check

#### Scenario: Monitoring is not configured or cannot be maintained
- **WHEN** a connected inbox lacks active provider monitoring
- **THEN** the dashboard SHALL identify the unavailable monitoring state and present relevant recovery or manual-check actions without falsely describing the inbox as monitored
