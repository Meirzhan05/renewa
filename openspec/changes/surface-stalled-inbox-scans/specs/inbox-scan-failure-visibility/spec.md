## ADDED Requirements

### Requirement: Dispatched scan without execution reaches terminal failure
A managed inbox scan that has been dispatched to the task runtime but produces no execution
within a bounded dispatch-grace window SHALL be transitioned to a terminal `failed` state with a
user-facing reason. The system MUST NOT report such a scan as `running` (or `0` discoveries)
indefinitely. The grace window MUST be configurable and default to a value at least as long as the
dispatched run's TTL.

#### Scenario: Run expires in the task runtime before any worker claims it
- **WHEN** a scan's dispatched run reaches the runtime's TTL with no connected/deployed worker
  (the run is EXPIRED and no `inbox_agent_executions` row was ever created)
- **THEN** within the grace window the corresponding `email_scan_run` is set to `failed` with a
  reason indicating the scan worker was unavailable, and the run is finalized

#### Scenario: App reflects the failure instead of an indefinite scan
- **WHEN** the app polls scan status for a run that failed under this rule
- **THEN** the status response reports `failed` with the user-facing reason, so the client stops
  showing an in-progress scan and surfaces the error

### Requirement: Dispatch outcomes are recorded, never silently swallowed
The edge SHALL record the outcome of dispatching a scan to the task runtime. A dispatch error
(missing credential, task not present in the deployed version, or transport failure) SHALL fail the
associated `email_scan_run` with a user-facing reason. The system MUST NOT return a healthy-looking
`queued`/`running` response when dispatch did not succeed.

#### Scenario: Dispatch throws
- **WHEN** the call that enqueues the scan run into the task runtime throws or returns a
  non-success result
- **THEN** the `email_scan_run` is marked `failed` with a reason derived from the dispatch error,
  and the failure is observable in scan status (not only in server logs)

### Requirement: Terminal task-runtime states resolve the scan
When a dispatched run reaches a terminal EXPIRED or failed state in the task runtime, the system
SHALL resolve the corresponding scan to `failed`, whether the signal arrives via a runtime callback
or is detected by the recovery reaper. Resolution MUST be idempotent — a scan already terminal is
not re-failed or reopened.

#### Scenario: Reaper detects an expired run with no execution
- **WHEN** the recovery reaper runs and finds an `email_scan_run` that is `running` past the
  dispatch-grace window with zero linked executions
- **THEN** it fails that run and finalizes it, and leaves already-terminal runs untouched

### Requirement: Orphaned worker jobs do not keep a scan reported active
Worker queue jobs whose parent `email_scan_run` no longer exists SHALL NOT contribute to any
liveness or active-scan signal, and SHALL be finalized so they are not drained or counted.

#### Scenario: Pending worker jobs from a deleted run
- **WHEN** the queue contains `pending` worker jobs referencing a `scan_run_id` with no matching
  `email_scan_run`
- **THEN** those jobs are finalized (failed/closed) and excluded from status liveness computation
