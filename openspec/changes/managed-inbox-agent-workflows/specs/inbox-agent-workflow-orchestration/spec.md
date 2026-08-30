## ADDED Requirements

### Requirement: A managed workflow owns each Inbox scan lifecycle
The system SHALL create a managed scan workflow for each eligible connection run. The workflow
SHALL coordinate pagination and page analysis through durable task identities while Supabase scan
run records remain the authoritative product lifecycle.

#### Scenario: A user starts a multi-page scan
- **WHEN** a scan's mailbox has more than one eligible page
- **THEN** the workflow SHALL create or schedule the required page operations with unique run/page
  identities and SHALL not require the iOS client to invoke later pages

### Requirement: Scan completion waits for all managed page outcomes
The workflow SHALL invoke the database completion coordinator after every terminal page outcome.
The scan run SHALL remain active while any linked page is queued, leased, running, or eligible for
retry.

#### Scenario: A page succeeds while a later page is waiting for capacity
- **WHEN** an earlier page has persisted review candidates and a later page remains queued or
  eligible for managed execution
- **THEN** the scan SHALL remain active and the earlier candidates SHALL remain available for
  review

### Requirement: Users can cancel active scans safely
The system SHALL allow an owner to request cancellation of an active scan. Cancellation SHALL stop
future page scheduling, prevent late results from entering the review queue, and settle the scan in
a user-safe terminal cancelled state.

#### Scenario: A user cancels while a page is already running
- **WHEN** the owner requests cancellation while a page task is executing
- **THEN** the workflow SHALL stop scheduling additional pages and the executing task SHALL discard
  its result before candidate persistence if it observes cancellation

### Requirement: Inbox progress is independent of task-runtime availability in the client
The authenticated Inbox status response SHALL derive user-visible progress from the Supabase scan
ledger and SHALL not require direct access to the managed runtime. It SHALL distinguish an active
capacity wait from completed, partial, failed, and cancelled terminal outcomes.

#### Scenario: A task waits for capacity
- **WHEN** an otherwise healthy page has not started because the configured agent capacity is full
- **THEN** the Inbox SHALL present the scan as active with a user-safe waiting/progress state rather
  than failed or completed
