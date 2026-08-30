## ADDED Requirements

### Requirement: Uncertain discoveries are surfaced, not auto-hidden

A first-time discovery ("add") candidate SHALL be auto-resolved (hidden from review) only when its
merchant is suppressed by the person or has explicitly ended (a cancellation supersedes it). A merchant
whose lifecycle is merely `uncertain` SHALL NOT cause the discovery to be hidden; it SHALL remain
pending for review.

#### Scenario: A detected subscription with incomplete evidence is shown
- **WHEN** the agent discovers a subscription whose merchant lifecycle is `uncertain` (e.g. no captured
  amount, or the latest receipt's renewal is in the past)
- **THEN** the candidate stays `pending` and appears in the review queue (it is not auto-ignored)

#### Scenario: An explicitly ended merchant is still hidden
- **WHEN** a discovery's merchant has an explicit later cancellation (lifecycle `ended`)
- **THEN** the candidate is auto-resolved and does not appear in the review queue

#### Scenario: A suppressed merchant is still hidden
- **WHEN** the person has suppressed discovery suggestions for the merchant
- **THEN** the candidate is auto-resolved and does not appear in the review queue

### Requirement: Reconciliation does not race an in-progress scan

Lifecycle reconciliation SHALL NOT auto-resolve a candidate whose scan run has not yet reached a
terminal state. A run's candidates become eligible for reconciliation only once that run is terminal.

#### Scenario: A candidate is not judged before its evidence is fully written
- **WHEN** a scan is still running and a discovery candidate has been created but the run has not
  finished writing all of that merchant's events
- **THEN** reconciliation does not resolve that candidate during the scan

#### Scenario: Settled candidates are still reconciled
- **WHEN** a candidate belongs to a terminal run and later evidence changes its merchant lifecycle
- **THEN** reconciliation still applies (e.g. a cancellation superseded by a later current renewal is
  resolved)

### Requirement: Reconciliation stays idempotent

Surfacing uncertain discoveries SHALL NOT change reconciliation's idempotency: repeated status polls
SHALL NOT duplicate, flip, or thrash a candidate's review state.

#### Scenario: Repeated polls are stable
- **WHEN** status is polled repeatedly for a user with pending uncertain discoveries
- **THEN** those candidates remain pending and no candidate is resolved or duplicated by the repeated
  polling
