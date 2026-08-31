## ADDED Requirements

### Requirement: Managed page work has bounded database ownership

Each managed Inbox page-analysis task SHALL use a bounded database connection lifecycle and SHALL
release every connection it owns when the task completes, fails, or is cancelled. Managed task traffic
SHALL use transaction-pool-compatible configuration in deployed environments.

#### Scenario: A completed page releases all of its connections
- **WHEN** a page analysis completes successfully
- **THEN** its application pool and LangGraph checkpoint connection resources are closed before the task
  is terminal

#### Scenario: A page fails during analysis
- **WHEN** a page analysis throws or times out
- **THEN** it releases every owned database connection before recording its retryable or failed outcome

### Requirement: Dispatch is durable and capacity-bounded

The execution ledger SHALL be the authority for dispatchable page work. A dispatcher SHALL atomically
reserve only ready, non-cancelled page executions and SHALL not exceed configured global, provider, or
per-user active-work budgets.

#### Scenario: Capacity prevents a connection burst
- **WHEN** the global page-analysis budget is four and more than four pages are ready
- **THEN** no more than four page executions are reserved or active at once

#### Scenario: Multiple users receive fair initial progress
- **WHEN** ready pages from several users exist and capacity is available
- **THEN** the dispatcher reserves one eligible page per user before reserving a second page for any of
  those users, subject to provider budgets

#### Scenario: Cancelled work is never dispatched
- **WHEN** a run has a cancellation request
- **THEN** the dispatcher does not reserve or submit any further page execution for that run

### Requirement: Retry is durable and singly owned

The dispatcher and execution ledger SHALL own redelivery of page work. A retryable or expired execution
SHALL be eligible for a future dispatched attempt without requiring a live local worker or a native
Trigger retry of the original task.

#### Scenario: A task failure becomes durable retry work
- **WHEN** a page task encounters a transient failure
- **THEN** it records retryable state and a next eligible time, and a later dispatcher invocation may
  submit a new attempt

#### Scenario: A reserved task is never started
- **WHEN** the dispatcher reserves work but the task runtime is unavailable before the task starts
- **THEN** lease recovery returns that execution to retryable work and a subsequent dispatcher run can
  submit it again

#### Scenario: Attempts are exhausted
- **WHEN** an execution reaches its configured attempt limit
- **THEN** its linked page job becomes failed and the scan run is finalized to a terminal failure when
  no active work remains

### Requirement: Dispatch and recovery are idempotent

Concurrent dispatcher, task, and recovery activity SHALL not duplicate a page analysis, candidate, or
terminal scan transition.

#### Scenario: Two dispatcher ticks overlap
- **WHEN** two dispatcher invocations inspect the same ready execution
- **THEN** at most one invocation reserves and submits that execution attempt

#### Scenario: A task finishes as its lease expires
- **WHEN** completion and recovery race for one execution
- **THEN** conditional state transitions preserve one valid terminal outcome without duplicating page
  results
