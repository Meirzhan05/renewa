## ADDED Requirements

### Requirement: Manual scan Live Activity lifecycle
The system SHALL offer an iOS Live Activity only for a scan explicitly started by the user from Inbox Intelligence and only when the current device supports and permits Live Activities. It MUST NOT start a Live Activity for automatic daily monitoring. The system SHALL end the Live Activity with the scan's terminal safe outcome.

#### Scenario: User starts a manual scan
- **WHEN** a user starts an inbox scan from Inbox Intelligence on an eligible device
- **THEN** the app starts one Live Activity for the returned scan batch and registers its ActivityKit push token with the authenticated server

#### Scenario: Daily monitoring begins a scan
- **WHEN** the automatic monitor begins an incremental inbox scan
- **THEN** the system does not start a Live Activity on any user device

### Requirement: Truthful scan progress presentation
The Live Activity and in-app scan presentation SHALL show durable scan stage, scanned-message count, and completed-inbox count as those values become available. The system SHALL show a percentage only when a provider supplies a reliable persisted total and scanned count for the same scan scope; otherwise it MUST omit percentage progress.

#### Scenario: Scan total is unknown
- **WHEN** a manual scan has scanned 8,421 messages but no reliable provider total is available
- **THEN** the Live Activity displays a stage and “8,421 messages checked” without a percentage

#### Scenario: Scan total is reliable
- **WHEN** a manual scan has a reliable total of 1,000 messages and has durably processed 600
- **THEN** the Live Activity may display 60 percent progress alongside its stage and count

### Requirement: Live Activity completion and duplicate suppression
The system SHALL end an active manual-scan Live Activity with a privacy-minimized terminal result. It MUST NOT send a duplicate ordinary outcome alert for the same batch to the installation that received that Live Activity result, while retaining eligible outcome delivery for the user's other enabled installations.

#### Scenario: Manual scan completes without discoveries
- **WHEN** a manual scan with an active Live Activity completes without new review-eligible candidates
- **THEN** the Live Activity ends with a “no new subscriptions found” result and the same device receives no duplicate ordinary alert

#### Scenario: User has another enabled device
- **WHEN** a manual scan completes with reviewable candidates and the user has a second enabled installation without the Live Activity
- **THEN** the second installation remains eligible for the deduplicated `review_ready` outcome alert

### Requirement: Live Activity privacy and stale-state handling
The system SHALL limit Live Activity content to scan stage, aggregate progress, outcome category, optional aggregate count, and an Inbox Intelligence route. It MUST NOT expose raw mail content, merchant names, evidence, or model output. If updates cannot reach a device, the activity SHALL become stale or end safely and the Inbox Intelligence screen SHALL remain the authoritative progress source.

#### Scenario: Device loses network connectivity during a scan
- **WHEN** an active Live Activity cannot receive a server update before its stale threshold
- **THEN** it no longer represents the displayed state as current and opening it routes the user to the live Inbox Intelligence status
