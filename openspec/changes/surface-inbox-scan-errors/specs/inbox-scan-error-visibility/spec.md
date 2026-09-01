## ADDED Requirements

### Requirement: Analysis failures reach a terminal state within bounded attempts
A managed page analysis SHALL NOT retry indefinitely. After a bounded number of attempts the execution
SHALL be marked `failed`, which fails its page and finalizes the owning `email_scan_run` as `failed`.
The system MUST NOT leave a run reporting in-progress while an execution retries forever.

#### Scenario: An analysis error recurs past the attempt cap
- **WHEN** a page analysis has failed and been retried up to the configured attempt cap
- **THEN** the execution is set `failed`, its scan job is failed, and the run is finalized `failed`
  with a user-safe reason (not left running)

#### Scenario: Reaper backstop for a perpetually-retryable execution
- **WHEN** the recovery reaper finds a `retryable` execution whose `dispatch_attempt` is at or past the
  cap
- **THEN** it fails that execution and finalizes the run, so no execution can loop indefinitely

### Requirement: Permanent provider errors fail fast
An error the provider will not recover from on retry — billing/quota exhaustion (e.g. HTTP 402
"insufficient balance") or authentication failure (e.g. HTTP 401 invalid key) — SHALL fail the
execution and run immediately, without consuming the full retry budget.

#### Scenario: LLM billing is exhausted
- **WHEN** the analysis provider returns a permanent billing/quota error
- **THEN** the run is failed immediately with an analysis-unavailable reason, rather than retried every
  minute

### Requirement: User-facing errors are safe categorized messages
Error text presented to a user SHALL be a friendly, categorized message and SHALL NOT contain raw
provider strings. Internal errors map to at least: analysis-unavailable, inbox-authorization, and a
generic scan-failure category. The mapping SHALL be applied before any message reaches the scan status
`errors[]`.

#### Scenario: A raw provider error is mapped
- **WHEN** an internal failure reason is a raw provider string such as "Insufficient Balance" or
  "Bad Request"
- **THEN** the status response exposes a categorized user-safe message (e.g. "We couldn't finish
  scanning — please try again later"), never the raw string

### Requirement: The app surfaces a failed scan distinctly with a retry
The app SHALL present a scan that finished in a `failed`/`partial` state as an unmistakable failure
state, distinct from the connection-scoped "needs attention" state, showing the categorized reason and
a retry affordance.

#### Scenario: A scan fails on analysis
- **WHEN** a scan reaches a terminal failed state for a non-connection reason
- **THEN** the scan screen shows a "couldn't finish" state with the user-safe reason and a Retry
  action, not an indefinite "scanning" state

### Requirement: Progress reflects distinct emails, not retried duplicates
The "emails checked" progress SHALL count each mailbox page once, even when that page's analysis is
retried. Retrying a page MUST NOT inflate the reported total.

#### Scenario: A page is retried several times
- **WHEN** one mailbox page (e.g. 100 messages) is analyzed and retried N times
- **THEN** the reported "checked" total reflects ~100, not 100×N
