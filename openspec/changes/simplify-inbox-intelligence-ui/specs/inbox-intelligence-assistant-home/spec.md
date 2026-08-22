## ADDED Requirements

### Requirement: Inbox Intelligence prioritizes the person’s current action
The system SHALL present Inbox Intelligence as a focused assistant surface whose default content prioritizes the current meaningful outcome over scanner diagnostics, account administration, or historical learning.

#### Scenario: Monitoring finds nothing requiring a decision
- **WHEN** an inbox is connected, monitoring is healthy, and no reviewable candidate is pending
- **THEN** the landing page SHALL show a concise no-action/monitoring state and SHALL not require the person to interpret metrics, lifecycle history, or diagnostic categories

#### Scenario: A reviewable discovery is pending
- **WHEN** one or more subscription candidates require review
- **THEN** the landing page SHALL lead with the pending reviewable discoveries and retain access to the existing review and dismissal flow

### Requirement: Routine scanner detail is progressively disclosed
The system SHALL keep connection management, alert preferences, manual scan control, scan history, paused suggestions, privacy guidance, and non-actionable scan outcomes outside the default landing flow in an Inbox settings or Scan details route.

#### Scenario: A person needs account or notification controls
- **WHEN** a person opens Inbox settings
- **THEN** the system SHALL provide the existing connection, reconnect/disconnect, alert, manual-check, history, suppression, and privacy controls without changing their safety behavior

#### Scenario: A person wants to understand a completed scan
- **WHEN** a person opens Scan details from the secondary route
- **THEN** the system SHALL provide privacy-minimized non-actionable outcomes and scan information without representing those outcomes as active subscriptions or required actions

### Requirement: Active scanning is visible without becoming a dashboard
The system SHALL show a compact, temporary scanning state only while durable scan work is active. It SHALL present the current stage and checked-message count when available, state that the work continues after leaving the tab, and SHALL not show an invented completion percentage or a persistent per-provider activity timeline.

#### Scenario: A scan is in progress
- **WHEN** the scan status is queued or running
- **THEN** the landing status surface SHALL show the current durable stage and available checked-message count while retaining any already-known reviewable discoveries

#### Scenario: A person leaves during a scan
- **WHEN** a person switches away from Inbox Intelligence while a scan is active
- **THEN** the system SHALL not report the expected local view-task cancellation as a scan error and SHALL refresh the durable outcome when the person returns

### Requirement: Recoverable inbox problems remain direct and actionable
The system SHALL surface an inbox failure on the landing page only when it needs a person’s action, with a safe recovery action that routes to the affected inbox setting or retry path.

#### Scenario: Provider authorization must be restored
- **WHEN** inbox monitoring or scanning reports that a provider connection needs reconnection
- **THEN** the landing page SHALL explain that attention is required and SHALL offer a direct reconnect path

#### Scenario: A non-authorization scan failure occurs
- **WHEN** a scan or status operation fails without a provider-reconnect remedy
- **THEN** the system SHALL preserve known content, show a human-readable recovery message in context, and offer the relevant retry action
