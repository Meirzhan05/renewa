## ADDED Requirements

### Requirement: Messages-checked count is cumulative across a run's pages

The app-visible "messages checked" figure for a scan SHALL equal the total number of mailbox messages
across **every page** fetched for that run, and SHALL be non-decreasing as the run progresses. It MUST
NOT be overwritten with the most recently processed page's count.

#### Scenario: Multi-page run reports the running total
- **WHEN** a run has processed 18 pages of 100 messages each and remains in progress
- **THEN** the status endpoint reports `scanned = 1800` (not 100)

#### Scenario: Count climbs while the scan is active
- **WHEN** a long scan has handed N pages to analysis and later hands an additional page
- **THEN** the reported `scanned` for that run increases by that page's message count and never decreases

#### Scenario: Single-page run
- **WHEN** a run has exactly one page of 40 messages
- **THEN** the reported `scanned` is 40

### Requirement: Changes-detected count reflects the run's actual surfaced events

The app-visible "changes detected" figure SHALL equal the number of billing events surfaced for the run
across all pages, derived from the run's persisted evidence/candidate rows rather than from a per-page
counter that is overwritten as pages complete.

#### Scenario: Detected count matches surfaced evidence
- **WHEN** a run has surfaced 6 detected billing events across its pages
- **THEN** the status endpoint reports `detected = 6` (not 0)

### Requirement: Likely-billing count is cumulative and billing-relevant

The app-visible "likely-billing emails" figure SHALL be cumulative across a run's pages and SHALL
reflect the messages the scan judged billing-relevant (the Tier-1 triage "look" set), not the raw
count of messages fetched.

#### Scenario: Likely-billing grows with triage across pages
- **WHEN** the triage step flags 3 billing-relevant messages on one page and 5 on the next
- **THEN** the reported likely-billing count for that run is at least 8 and never decreases

### Requirement: Progress counts are retry-safe

Reprocessing or retrying a mailbox page (task retry, re-claim, or duplicate delivery) SHALL NOT
double-count or reset any progress figure. Each distinct page contributes to the totals exactly once.

#### Scenario: A retried page does not inflate the total
- **WHEN** a page that was already counted is re-executed after a transient failure
- **THEN** the run's `scanned`, likely-billing, and `detected` totals are unchanged by the re-execution

### Requirement: Batch totals aggregate across connections

When a scan spans multiple inbox connections (multiple runs in one batch), the app-visible aggregate
totals SHALL be the sum over all runs and all of their pages.

#### Scenario: Two connected inboxes
- **WHEN** connection A scanned 1200 messages and connection B scanned 600 in the same batch
- **THEN** the aggregate `scanned` reported to the app is 1800

### Requirement: No client contract change

The corrected figures SHALL be produced by the existing `email-scan` status response fields
(`scanned` / `candidate_messages` / `detected`, and the per-run entries in `runs[]`). The
`POST /functions/v1/email-scan` request and response shape SHALL remain unchanged, requiring no iOS
client modification.

#### Scenario: Existing poll loop renders correct progress unchanged
- **WHEN** the unchanged iOS client polls scan status during a multi-page scan
- **THEN** it renders an increasing "messages checked" value using the same response fields as before
