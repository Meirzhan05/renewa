## ADDED Requirements

### Requirement: Page database connection survives long model calls

A single managed inbox-page analysis SHALL hold a usable database connection across the LLM calls it performs, without being forced to re-establish that connection mid-page. The page's connection pool SHALL NOT idle-close a connection on a timescale shorter than a page's maximum run duration, so that a checkpoint write issued after a model call reuses the existing connection rather than reconnecting.

#### Scenario: Checkpoint write after a long LLM call reuses the connection

- **WHEN** a page runs an LLM call that lasts longer than the pool's previous 10s idle timeout, then issues a checkpoint write
- **THEN** the write reuses the already-open connection and does not fail with "timeout exceeded when trying to connect"

#### Scenario: Idle timeout is not shorter than the page ceiling

- **WHEN** the managed page pool is constructed
- **THEN** its idle-close behavior SHALL NOT expire a connection before the task's `maxDuration` (the page ceiling), so no normal in-page gap between DB operations triggers a reconnect

### Requirement: Connection acquisition tolerates transient contention and pooler pressure

The managed page pool SHALL provide enough connection headroom that the periodic execution heartbeat never competes with a checkpoint write for a single connection, and connection acquisition SHALL be given a budget generous enough to absorb brief transaction-pooler pressure rather than failing on the first slow reconnect.

#### Scenario: Heartbeat does not contend with a checkpoint write

- **WHEN** the 45s execution heartbeat query fires while a checkpoint write is holding a connection
- **THEN** the heartbeat acquires its own connection and both complete, without either waiting out the connect timeout

#### Scenario: Brief pooler pressure does not immediately fail the page

- **WHEN** acquiring a connection encounters brief transaction-pooler pressure
- **THEN** acquisition waits within its configured budget (and/or retries) before surfacing an error, rather than failing on a single sub-second stall

### Requirement: Database failures never crash the page task

A database failure that occurs while analyzing a page — including a fire-and-forget heartbeat query and any detached checkpoint write — SHALL be contained and routed through the durable retry ledger. Such a failure MUST NOT surface as an uncaught task exception, so the already-shipped `retryable`/`failed` handling (and its retry cap) governs the outcome instead of an unhandled process crash.

#### Scenario: Heartbeat rejection does not terminate the task

- **WHEN** the fire-and-forget heartbeat `pool.query` rejects (e.g. a connect timeout)
- **THEN** the rejection is caught and logged, the page continues or fails through its normal path, and the task does not end in `TASK_RUN_UNCAUGHT_EXCEPTION`

#### Scenario: A DB error during analysis completes the execution as retryable

- **WHEN** a checkpoint or store operation fails with a transient database error during analysis
- **THEN** the execution is completed as `retryable` via `complete_inbox_agent_execution` (or `failed` if the error is permanent), rather than escaping as an uncaught exception that leaves the execution leased until a reaper reclaims it
