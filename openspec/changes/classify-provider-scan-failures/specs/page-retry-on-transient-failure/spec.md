## ADDED Requirements

### Requirement: A transient page failure is retried before the run fails
A scan page that fails for a transient reason SHALL be retried with backoff before the scan run is
marked failed. A single transient provider failure SHALL NOT discard a scan that has already read
earlier pages successfully.

#### Scenario: A rate-limited page is retried
- **WHEN** a page fails because the provider was rate limiting and the page has attempts remaining
- **THEN** the page is returned to the queue with a later availability time and the run stays running

#### Scenario: A provider outage is retried
- **WHEN** a page fails because the provider was unavailable and the page has attempts remaining
- **THEN** the page is returned to the queue rather than failing the run

#### Scenario: Backoff grows with attempts
- **WHEN** a page is retried more than once
- **THEN** each retry waits longer than the previous one

#### Scenario: Earlier pages are not discarded
- **WHEN** a later page is retried
- **THEN** the pages already completed in that run keep their results

### Requirement: An authorization failure is not retried
A failure that retrying cannot fix SHALL fail immediately rather than consuming its attempts. A
revoked or expired credential SHALL fail the page on its first occurrence.

#### Scenario: A revoked token fails fast
- **WHEN** a page fails with an authorization failure
- **THEN** the page is marked failed without being re-queued

#### Scenario: The user is told to reconnect once
- **WHEN** an authorization failure ends a scan
- **THEN** the user is asked to reconnect, and the scan does not retry two more times first

### Requirement: Exhausted retries fail the run as before
When a retryable failure has used its attempts, the page SHALL fail and the run SHALL be finalized
through the existing failure path. Retrying SHALL NOT cause a failure to be swallowed or a run to
hang.

#### Scenario: The last attempt fails the page
- **WHEN** a page's final permitted attempt fails
- **THEN** the page is marked failed and the run is finalized

#### Scenario: A retried page that later succeeds finalizes normally
- **WHEN** a page fails once, is retried, and then succeeds
- **THEN** the run continues and completes as though the failure had not happened

#### Scenario: Retrying never leaves a run running forever
- **WHEN** every page has either completed or exhausted its attempts
- **THEN** the run reaches a terminal state
