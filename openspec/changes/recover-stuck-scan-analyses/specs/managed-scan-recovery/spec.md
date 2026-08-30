## ADDED Requirements

### Requirement: A page analysis is time-bounded

A single mailbox-page analysis SHALL NOT run indefinitely. Its model/LLM calls and the page as a whole
SHALL be bounded by a timeout, after which the task fails rather than hanging.

#### Scenario: A hung model call is aborted, not left running for an hour
- **WHEN** a page's model call exceeds its configured timeout
- **THEN** the page task fails (and becomes eligible for the normal retry) instead of running up to the
  task's maximum duration

#### Scenario: The page task maximum duration is a realistic budget
- **WHEN** a page analysis is dispatched
- **THEN** its maximum duration is on the order of minutes, not an hour

### Requirement: Orphaned executions are reclaimed automatically

An execution whose lease has expired without a heartbeat (its task crashed or was killed) SHALL be
reclaimed automatically on a fixed cadence, without manual intervention.

#### Scenario: A killed task's execution is reclaimed
- **WHEN** an execution is `running` with `lease_expires_at` in the past and no live heartbeat
- **THEN** the scheduled recovery marks it retryable (under the attempt cap) or failed (past it),
  within a bounded time of the lease expiring

#### Scenario: A live task is never reclaimed
- **WHEN** a page task is still executing and heartbeating (extending its lease)
- **THEN** recovery does not touch its execution

### Requirement: Recovery resolves the run, never deadlocks it

When recovery gives up on an execution (past the retry cap), it SHALL fail the linked page job and
finalize the scan run, so a dead task drives the run to a terminal state instead of leaving it running
forever. Candidates already surfaced by other pages SHALL be preserved.

#### Scenario: A terminally dead page finalizes the run
- **WHEN** an execution is reclaimed as failed past the retry cap and its `scan_jobs` row is still active
- **THEN** that page job is failed and the run is finalized to a terminal state, and the subscriptions
  found by the completed pages remain available for review

#### Scenario: No permanent "running" run
- **WHEN** every page of a run has reached a terminal state through completion or recovery
- **THEN** the run is finalized and no run remains `running` indefinitely after its work is dead

### Requirement: Recovery is idempotent and safe under races

Recovery SHALL be safe to run repeatedly and concurrently with normal task completion: it SHALL only
act on genuinely expired executions and SHALL not double-finalize or double-fail.

#### Scenario: Repeated recovery runs do not corrupt state
- **WHEN** the recovery routine runs again over a run it already finalized
- **THEN** no candidate, event, or job is duplicated and the run stays terminal
