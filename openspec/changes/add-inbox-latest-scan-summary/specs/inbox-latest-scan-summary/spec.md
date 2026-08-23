## ADDED Requirements

### Requirement: Inbox Intelligence shows a compact latest-check proof of work
The system SHALL show one privacy-minimized Latest check summary on the Inbox Intelligence landing page when a connected inbox has a durable completed check. The summary SHALL appear after the current-state card and before reviewable discoveries, and SHALL identify the relevant provider or aggregate inbox label, relative completion time, and a plain-language result.

#### Scenario: A completed check needs no review
- **WHEN** a connected inbox has a completed check with no pending subscription candidate
- **THEN** the landing page SHALL show that no new subscription change needs review and SHALL identify when the latest check completed

#### Scenario: A completed check has reviewable discoveries
- **WHEN** a completed check has one or more pending subscription candidates
- **THEN** the landing page SHALL show the compact latest-check summary before the primary reviewable-discovery section

#### Scenario: No inbox has completed a check
- **WHEN** no inbox is connected or no completed-check information is available
- **THEN** the system SHALL omit the Latest check summary and SHALL retain the applicable no-inbox or active-scan state

### Requirement: Latest-check metrics are truthful and secondary
The system SHALL present checked-message and likely-billing counts only when the current durable status provides meaningful completed-scan values. It MUST label them as information about the latest check, SHALL omit unsupported or misleading values, and SHALL not present a percentage, a period aggregate, or a repeated pending-review metric.

#### Scenario: Completed work exposes counts
- **WHEN** a completed scan has a trustworthy non-zero checked-message count
- **THEN** the Latest check summary SHALL show the checked-message count and may show the likely-billing count using privacy-safe aggregate language

#### Scenario: Completed work has no trustworthy count
- **WHEN** a completed scan does not expose a meaningful checked-message count
- **THEN** the Latest check summary SHALL retain provider, time, and outcome information without showing a zero-filled metrics row

### Requirement: Expanded scan history remains progressively disclosed
The Latest check summary SHALL provide a Scan details disclosure that routes to the existing privacy-minimized details experience. It MUST NOT expand a historical timeline, non-actionable lifecycle feed, raw email content, full mailbox address, or model output on the landing page.

#### Scenario: A person opens scan details
- **WHEN** a person selects Scan details from the latest-check summary
- **THEN** the system SHALL open the secondary details route with only the existing privacy-minimized scan information
