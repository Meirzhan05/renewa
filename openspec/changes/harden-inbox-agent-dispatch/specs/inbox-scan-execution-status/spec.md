## ADDED Requirements

### Requirement: Scan status represents durable execution state

The Inbox scan status SHALL distinguish fetching, queued analysis, active analysis, retrying,
cancel-requested, completed, failed, and cancelled work using the durable page and execution ledger.
It SHALL not infer completion from the state of an Edge Function request or a local terminal process.

#### Scenario: Fetching is complete while analysis remains
- **WHEN** all historical pages have been fetched but some page executions are queued, leased, running,
  or retryable
- **THEN** the app reports the fetched message count and an active analysis/queueing state rather than
  reporting the scan as complete or silently stopped

#### Scenario: A retry is visible
- **WHEN** a page execution is retryable and has a future eligible time
- **THEN** the app reports that the scan is retrying and remains non-terminal

#### Scenario: All page work is terminal
- **WHEN** every page execution and page job for a run is completed, failed, or cancelled
- **THEN** the run is finalized exactly once as completed, failed, or cancelled

### Requirement: Users can stop an active scan

The Inbox SHALL expose a Stop action for a cancellable scan. A stop request SHALL be persisted before
the UI confirms it, prevent new page dispatch, and resolve the run to cancelled after in-flight work
reaches a safe boundary.

#### Scenario: Stop while pages are queued
- **WHEN** a user stops a scan with queued or retryable pages
- **THEN** those pages are cancelled and no new analysis task is submitted for them

#### Scenario: Stop while a page is active
- **WHEN** a user stops a scan with an active page analysis
- **THEN** the active task observes cancellation before surfacing additional results and the run becomes
  cancelled once active work has settled

### Requirement: Terminal failure is actionable

When a page cannot be recovered within the attempt budget, the Inbox SHALL report a terminal failed
scan with a safe error message and retain candidates from pages that completed before the failure.

#### Scenario: One page exhausts recovery
- **WHEN** a page exhausts its retry attempts
- **THEN** the run is shown as failed rather than indefinitely preparing or scanning, and prior valid
  discoveries remain available
