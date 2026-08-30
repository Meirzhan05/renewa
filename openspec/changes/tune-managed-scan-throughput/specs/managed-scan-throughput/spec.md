## ADDED Requirements

### Requirement: Page analysis runs concurrently within a run

An inbox scan SHALL analyze its mailbox pages concurrently rather than one at a time, up to the
configured per-user analysis budget. Raising that budget SHALL actually increase in-flight analyses
(the orchestrator must dispatch more than one at a time).

#### Scenario: Multiple pages analyze in parallel
- **WHEN** a run has fetched 8 pages and the per-user budget is 4
- **THEN** up to 4 page analyses execute concurrently until all 8 are done

#### Scenario: Budget of one preserves serial behavior
- **WHEN** the per-user budget is set to 1
- **THEN** at most one page analysis runs at a time (the prior behavior remains available)

### Requirement: Fetch remains sequential

Mailbox pages SHALL be fetched in continuation order, one page at a time, because each page's
provider cursor depends on the previous fetch. Only analysis fans out.

#### Scenario: Cursor integrity under parallel analysis
- **WHEN** a run pages through a large mailbox while analyses run in parallel
- **THEN** each page is fetched from the prior page's continuation cursor, in order, with no
  concurrent fetches

### Requirement: Concurrency stays within configured budgets

Concurrent analysis SHALL respect the per-user, provider, and global ceilings; a single user's scan
SHALL NOT exceed its per-user budget, and total concurrent analyses SHALL NOT exceed the global
ceiling.

#### Scenario: One large scan does not monopolize the pool
- **WHEN** one user runs a large multi-page scan and others start scans
- **THEN** the large scan uses at most its per-user budget and other users still make progress

### Requirement: Correctness is preserved under parallel dispatch

Parallel analysis SHALL NOT change run correctness: no candidate or event is duplicated, a run
completes only after every page is terminal, and page retries remain safe.

#### Scenario: Out-of-order page completion still completes the run once
- **WHEN** pages complete in a different order than fetched
- **THEN** the run is finalized exactly once, after the last page reaches a terminal state

#### Scenario: A redelivered page does not double-surface
- **WHEN** a page analysis is delivered or retried more than once
- **THEN** its idempotency key prevents a duplicate candidate or event

### Requirement: Cancellation stops further analysis

A cancellation request SHALL stop scheduling further page analyses, and in-flight analyses of a
cancelled run SHALL NOT surface results.

#### Scenario: Cancel mid-scan
- **WHEN** a user cancels a scan while pages are still being fetched or analyzed
- **THEN** no further pages are dispatched and the run resolves cancelled

### Requirement: No client contract change

Intra-run parallelism SHALL be internal to the managed runtime; the `email-scan` request/response
shape and the iOS client SHALL be unaffected.

#### Scenario: Client is unchanged
- **WHEN** the unchanged iOS client polls a scan that now analyzes pages in parallel
- **THEN** it observes the same status/progress fields, just reaching completion sooner
