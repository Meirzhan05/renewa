## ADDED Requirements

### Requirement: Inbox agents execute from a managed deployed runtime
The system SHALL execute production Inbox agent work through a managed deployed task runtime. A
user scan SHALL not depend on a developer process, local `npm` command, or an iOS client remaining
open.

#### Scenario: A scan starts with no local worker running
- **WHEN** an authenticated user starts a valid Inbox scan and no developer worker is running
- **THEN** the managed runtime SHALL accept the eligible agent work and the scan SHALL make
  server-side progress

### Requirement: Agent execution is bounded and fair across users
The system SHALL enforce configurable global, provider-specific, and per-user concurrency limits
for active page analysis. Eligible work from a user with an active historical scan SHALL NOT
monopolize capacity needed by other eligible users.

#### Scenario: Many users start scans simultaneously
- **WHEN** multiple users start scans while active agent capacity is exhausted
- **THEN** the system SHALL retain their work durably, admit it as capacity becomes available, and
  enforce the configured per-user and provider limits

#### Scenario: One user has many historical pages
- **WHEN** one user has multiple eligible page-analysis tasks and another user has eligible work
- **THEN** admission SHALL not start all of the first user's pages before admitting the other
  user's eligible work solely because the first user's scan was created earlier

### Requirement: Page work is recoverable and idempotent
Every page-analysis operation SHALL have a deterministic idempotency identity and durable execution
state. The system SHALL safely retry eligible interrupted work without duplicating candidate,
billing-event, or terminal scan writes.

#### Scenario: A worker terminates during page analysis
- **WHEN** a managed task stops producing heartbeats before its lease expires
- **THEN** a recovery process SHALL make the page eligible for a bounded retry and preserve the
  scan as nonterminal until a terminal outcome is recorded

#### Scenario: A task is delivered more than once
- **WHEN** the runtime re-delivers an operation whose prior attempt already persisted its outcome
- **THEN** the duplicate attempt SHALL not create an additional review candidate or alter an
  already terminal outcome

### Requirement: Agent credentials and operational data remain server-side
Managed task payloads SHALL contain opaque identifiers rather than provider access tokens, raw email
bodies, or user-visible queue data. Credentials SHALL be obtained only through the server-side
credential path when a task needs them and SHALL not be logged.

#### Scenario: A page analysis task is submitted
- **WHEN** the orchestration service triggers a managed page task
- **THEN** its payload SHALL identify the run and page without including a provider access token or
  raw email content

### Requirement: Agent execution is observable without exposing internals to users
The system SHALL record correlated task attempts, state transitions, retries, and terminal errors
for authorized operations, while the client-facing API returns only owner-safe scan progress and
outcomes.

#### Scenario: An agent task fails permanently
- **WHEN** a page exhausts its retry policy
- **THEN** authorized operators SHALL be able to trace the failed attempt to its scan run and the
  user-facing scan status SHALL expose a safe terminal outcome without task-platform identifiers
