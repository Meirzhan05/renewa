## MODIFIED Requirements

### Requirement: Agent proposals bridge into the app review queue

Proposals the worker records (as `scan_outcomes` of kind `present`) SHALL be bridged into the app's
`subscription_candidates` table so the existing iOS review UI surfaces them unchanged, and the scan
run's status SHALL be readable by the app. The app-visible aggregate scan status SHALL reflect the
**worker's actual progress on the run** — a run that has been handed to the worker but not yet
finalized SHALL report as still in progress (not `completed`), so the app keeps polling until the
worker has finished and any candidates are queryable. The status endpoint SHALL NOT report a run as
`completed` merely because the edge function finished enqueuing the mailbox window for the worker.

#### Scenario: A proposal becomes a review-queue candidate

- **WHEN** the worker records a `present` outcome for a merchant
- **THEN** a corresponding `subscription_candidates` row is created (respecting suppression and
  duplicate-tracking rules) and appears in the app's review queue

#### Scenario: A handed-off run reports as in progress until the worker finalizes it

- **WHEN** the app polls scan status after the edge function has fetched the mailbox window and
  enqueued the worker job, but the worker has not yet finalized the run
- **THEN** the aggregate `status` reported to the app is a still-active value (queued/running), not
  `completed`, so the app continues polling

#### Scenario: Completion reflects worker completion, including surfaced candidates

- **WHEN** the worker finalizes the run (records its outcome and bridges any proposals into
  `subscription_candidates`) and the app next polls status
- **THEN** the aggregate `status` becomes a terminal value and the response includes the pending
  candidate count, so the app renders the review queue instead of a false "nothing to review"

## ADDED Requirements

### Requirement: A never-processed scan resolves to a failed state, not a false empty completion

When no worker drains the queue (worker not deployed or down), a started scan SHALL NOT be reported
to the app as a successful empty completion. After a bounded time with the run handed off but never
finalized by a worker, the status endpoint SHALL report the run as failed or partial so the app
surfaces an honest "couldn't finish" state rather than "no subscriptions found".

#### Scenario: Worker never claims the job

- **WHEN** a scan has been enqueued for the worker and no worker finalizes the run within the
  configured completion-timeout window
- **THEN** the app-visible aggregate `status` for that scan is `failed` (or `partial` when at least
  one connection finalized), and an error is surfaced — not `completed` with zero candidates

#### Scenario: Slow-but-alive worker is not prematurely failed

- **WHEN** the worker is still actively processing the run within the completion-timeout window
- **THEN** the status remains a still-active value and is not marked failed, allowing the run to
  complete normally
