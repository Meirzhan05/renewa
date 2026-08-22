## ADDED Requirements

### Requirement: Inbox Intelligence communicates monitoring health truthfully
The Inbox Intelligence dashboard SHALL describe the connected inbox’s monitoring state as active, checking, degraded with reconciliation available, or reconnect required. It SHALL not claim continuous or real-time monitoring unless its corresponding server monitoring state is active.

#### Scenario: Provider monitoring is active
- **WHEN** a connected inbox has an active provider watch and a successful recent check
- **THEN** the dashboard SHALL state that new inbox activity is monitored automatically and show a privacy-minimized last-check time

#### Scenario: Provider monitoring is degraded
- **WHEN** the provider watch is unavailable but daily reconciliation remains configured
- **THEN** the dashboard SHALL explain that monitoring needs attention while indicating the available fallback without claiming event-driven monitoring is active

### Requirement: Manual checks are optional recovery controls
The Inbox Intelligence dashboard SHALL present a manual check as an optional “Check now” control for immediate reassurance or recovery, rather than as the primary mechanism for discovering new billing events.

#### Scenario: A healthy inbox is displayed
- **WHEN** an inbox is actively monitored and no scan is running
- **THEN** the dashboard SHALL prioritize monitoring health and present “Check now” as a secondary optional action

### Requirement: Monitoring failures have actionable recovery guidance
The dashboard SHALL identify connection or provider-monitoring failures without exposing credentials, raw email content, provider tokens, or raw provider event payloads.

#### Scenario: Reconnection is required
- **WHEN** a provider rejects a cursor read or monitoring renewal because authorization is invalid
- **THEN** the dashboard SHALL show that the inbox needs reconnection and provide the existing reconnect path
