## ADDED Requirements

### Requirement: A paginated scan remains active until all of its work is terminal
The system SHALL treat all edge mailbox-page jobs and persistent worker jobs linked to an inbox scan
run as one lifecycle. Persisting candidates from an individual worker page SHALL NOT complete the
run. The run SHALL become terminal only after every linked job has reached a terminal state.

#### Scenario: First worker page finishes while later pages remain queued
- **WHEN** a worker finishes one page of a multi-page scan and at least one linked edge or worker
  job remains queued, pending, or running
- **THEN** the scan run remains active and the Inbox SHALL NOT report the scan as complete

#### Scenario: Last successful page finishes
- **WHEN** every linked edge and worker job for a run has completed without failure
- **THEN** the system SHALL persist the run as completed and use `review_ready` when pending review
  candidates exist, otherwise `completed`

#### Scenario: A page fails after earlier pages produced candidates
- **WHEN** one linked job has failed and no linked job remains active
- **THEN** the system SHALL persist that run as failed while retaining candidates that earlier pages
  safely produced

### Requirement: App-visible scan status reflects all active page work
The authenticated inbox scan status response SHALL derive a run's active or terminal state from all
of its linked queue rows. A linked active edge or worker job SHALL make the enclosing run active,
regardless of a stale terminal value previously stored on the run. A batch with one failed run and
one completed run SHALL report a partial terminal state.

#### Scenario: A stale run record conflicts with active worker pages
- **WHEN** a run record is marked completed but a linked worker job is pending or running
- **THEN** the status response SHALL report the run and aggregate batch as active

#### Scenario: Multiple worker jobs share one run
- **WHEN** the status endpoint evaluates a run with multiple linked worker jobs in different states
- **THEN** it SHALL account for every job instead of selecting one job arbitrarily

#### Scenario: Connected inboxes finish with mixed outcomes
- **WHEN** all jobs are terminal and at least one connection run failed while another completed
- **THEN** the status response SHALL report the batch as partial and preserve its completed review
  candidates

### Requirement: Inbox remains synchronized with a long-running active scan
While the Inbox is visible or the app returns to the foreground, the client SHALL continue to refresh
an active scan until it reaches a terminal status. The client SHALL use a paced polling cadence and
SHALL cancel polling when the task is no longer relevant, the user signs out, or the scan is terminal.

#### Scenario: A scan exceeds the former four-minute polling limit
- **WHEN** a scan remains active beyond four minutes
- **THEN** the Inbox SHALL continue to refresh its status and continue to present an active scan

#### Scenario: The app returns to an active scan
- **WHEN** the Inbox becomes visible or the app returns to the foreground while its latest scan is
  active
- **THEN** the client SHALL reload the scan status and resume polling

#### Scenario: A status refresh fails transiently
- **WHEN** a refresh request for an active scan fails transiently
- **THEN** the client SHALL retain the last active state and retry with bounded backoff rather than
  presenting the scan as complete
