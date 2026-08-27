## ADDED Requirements

### Requirement: Tier-1 model reads every email
The system SHALL pass every fetched email's metadata (subject, sender, snippet, received-at)
through a cheap triage model on the main path. No email SHALL be excluded from triage by a
hand-maintained keyword rule; keyword heuristics MAY exist only as an availability fallback.

#### Scenario: Every email is triaged
- **WHEN** a scan fetches N emails
- **THEN** the triage model is asked to decide on all N emails' metadata
- **AND** no email is filtered out before triage by a static keyword list

#### Scenario: Bodies are never read at triage
- **WHEN** the triage model evaluates an email
- **THEN** it receives only metadata and a short snippet, never the full body

### Requirement: Triage returns a look/skip decision, not a score
The triage model SHALL return a discrete `look` or `skip` decision per email. The system SHALL NOT
apply a hand-tuned numeric confidence cutoff to convert a score into that decision.

#### Scenario: Decision drives routing
- **WHEN** the triage model marks an email `look`
- **THEN** the email is forwarded to the autonomous agent

#### Scenario: No threshold constant
- **WHEN** triage output is processed
- **THEN** routing depends only on the model's look/skip decision, with no numeric admit threshold

### Requirement: Triage is recall-biased
The triage model SHALL be instructed to prefer `look` when uncertain, because the expensive agent
supplies precision downstream. Ambiguous or plausibly subscription-related mail SHALL be passed up.

#### Scenario: Uncertain mail is passed up
- **WHEN** an email is ambiguous between a receipt and unrelated mail
- **THEN** the triage model returns `look` rather than `skip`

### Requirement: Skips are measured by sampling
Because a `skip` is a permanent drop, the system SHALL periodically route a small random sample of
skipped emails through the autonomous agent to estimate the triage false-negative rate, using the
same sanitize/truncate path as the main flow.

#### Scenario: Random skip sample is re-evaluated
- **WHEN** a scan completes and the skip-sampling probe is due
- **THEN** a bounded random sample of skipped emails is sent to the agent
- **AND** any that the agent would have surfaced are recorded as triage misses

### Requirement: Triage degrades without silent loss
WHEN the triage model is unavailable, the system SHALL NOT permanently drop the affected emails: it
SHALL retry the batch or degrade to a recall-only fallback so an outage reduces reliability, never
correctness.

#### Scenario: Triage outage does not drop mail
- **WHEN** the triage model call fails for a batch
- **THEN** the batch is retried or handled by the recall fallback
- **AND** the emails are not silently discarded

### Requirement: Triage does not perform merchant grouping
The triage model SHALL operate per-email and SHALL NOT assign canonical merchant identity. Merchant
grouping is the autonomous agent's responsibility. Triage MAY emit a cheap best-guess merchant hint
as an optional aid.

#### Scenario: Grouping is deferred to the agent
- **WHEN** two emails from the same merchant are triaged
- **THEN** triage decides look/skip for each independently, without merging them into one merchant
