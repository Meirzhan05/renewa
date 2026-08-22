## ADDED Requirements

### Requirement: Inbox Intelligence exposes a scan-health summary
The system SHALL present a state-specific Inbox Intelligence summary for every signed-in user that identifies whether an inbox is connected, whether a scan is running, whether a scan needs attention, or the meaningful result of the latest completed scan. When available, the summary SHALL present the connected provider, background-monitoring status, last completion time, messages checked, likely billing messages, and reviewable-change count using privacy-minimized data.

#### Scenario: Completed scan requires no review
- **WHEN** the latest completed scan has no pending reviewable candidates
- **THEN** the summary SHALL state that no action is needed and SHALL not present the outcome as an empty or failed scan

#### Scenario: No inbox is connected
- **WHEN** the user has no connected inbox
- **THEN** the summary SHALL explain the read-only connection option and provide a path to connect an inbox

#### Scenario: Daily monitoring is active
- **WHEN** the connection is enabled for automatic monitoring
- **THEN** the summary SHALL identify that new mail is monitored automatically without claiming an unsupported real-time cadence

### Requirement: Active scans communicate durable progress and background behavior
The system SHALL show active scan progress using durable stage and count data. It SHALL state that the scan can continue after the person leaves the Inbox Intelligence tab, and SHALL not show a percentage when the provider has not supplied a trustworthy total message count.

#### Scenario: A historical scan is processing
- **WHEN** a scan run is queued, fetching, filtering, extracting, or reconciling evidence
- **THEN** the dashboard SHALL show the current stage and checked-message count while retaining the rest of the known dashboard content

#### Scenario: The person changes tabs during an active scan
- **WHEN** the person leaves Inbox Intelligence while the scan job is still active
- **THEN** the app SHALL not present the expected local task cancellation as a scan failure and SHALL show the refreshed durable state when the person returns

### Requirement: Reviewable changes are visually separated from scan learning
The system SHALL place pending subscription candidates in a primary “Actions for you” section. It SHALL place ended, uncertain, ambiguous, or otherwise non-actionable evidence outside that section and SHALL not count those outcomes as active subscriptions or requested actions.

#### Scenario: A scan finds a reviewable subscription change
- **WHEN** a completed scan has one or more pending candidates
- **THEN** the dashboard SHALL show the candidate count and provide access to the existing review flow before non-actionable history

#### Scenario: A scan finds only non-actionable evidence
- **WHEN** a completed scan records ended, uncertain, or withheld evidence but no pending candidate
- **THEN** the dashboard SHALL show a privacy-minimized learning summary that explains why no action was requested

### Requirement: Scan details protect mailbox privacy while explaining outcomes
The system SHALL provide a scan-detail experience for eligible summaries and reviewable evidence using only merchant label, event type, received date, lifecycle/result reason, and a non-verbatim explanation. It MUST NOT display raw email bodies, complete mailbox addresses, raw model output, tokens, or unvalidated extracted fields.

#### Scenario: A person opens non-actionable evidence
- **WHEN** the person requests the details for an ended or uncertain result
- **THEN** the detail view SHALL explain the non-actionable lifecycle outcome without presenting it as an active subscription

#### Scenario: A candidate has multiple supporting events
- **WHEN** a reviewable candidate is supported by more than one validated event
- **THEN** the detail view SHALL present a compact chronological evidence summary and the reason the proposed action is eligible

### Requirement: Loading and failure presentation is bounded and actionable
The system SHALL limit skeleton loading to unresolved content during an initial dashboard request. Once durable scan or connection status is known, it SHALL retain that status while subsequent work occurs. Failures SHALL appear in their affected context with a safe recovery action and a human-readable reason.

#### Scenario: Dashboard data is loading for the first time
- **WHEN** the dashboard has no known scan or connection state and the initial request is pending
- **THEN** the app SHALL show a bounded loading placeholder only for the unresolved dashboard content

#### Scenario: A scan fails because authorization must be restored
- **WHEN** the scan response identifies a provider authorization failure
- **THEN** the affected summary SHALL explain that the inbox needs reconnection and offer the relevant reconnect action

#### Scenario: A scan request fails for another reason
- **WHEN** a scan request or status refresh fails without an authorization-recovery path
- **THEN** the affected section SHALL keep known content visible and offer a retry action with a human-readable error message
