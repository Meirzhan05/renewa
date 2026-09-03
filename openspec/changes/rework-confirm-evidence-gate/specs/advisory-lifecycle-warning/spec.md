## ADDED Requirements

### Requirement: A human confirmation is never silently overruled
The server SHALL NOT resolve, ignore, or discard a candidate that a user explicitly confirmed. When
lifecycle evidence suggests the confirmation may be stale, the server SHALL return the candidate
unapplied with a warning, leaving it pending, rather than marking it ignored.

#### Scenario: Stale evidence produces a warning, not a resolution
- **WHEN** a user confirms a candidate whose reconstructed lifecycle state is not `current`
- **THEN** the candidate's review status remains `pending`, no subscription is created, and the
  response carries a warning outcome

#### Scenario: A warned candidate is still in the queue afterwards
- **WHEN** a confirmation returns a warning and the user takes no further action
- **THEN** the card is still present and pending on the next load of the inbox

#### Scenario: Automatic resolution paths are unaffected
- **WHEN** the system resolves a candidate without a user decision, such as during scan reconciliation
- **THEN** it MAY still mark the candidate resolved with a system reason, because no human
  confirmation is being overruled

### Requirement: A warned confirmation applies when the user acknowledges it
A confirmation request SHALL be able to carry an explicit acknowledgement of a prior warning. When
present, the server SHALL apply the confirmation without re-issuing the same warning.

#### Scenario: Acknowledged confirmation applies
- **WHEN** a user is shown a staleness warning, chooses to proceed, and the confirmation is
  re-submitted with an acknowledgement
- **THEN** the subscription is created or updated and the candidate reaches `confirmed` with a
  non-null applied subscription

#### Scenario: Declining leaves everything untouched
- **WHEN** a user is shown a staleness warning and chooses not to proceed
- **THEN** no subscription is created, the candidate remains pending, and nothing is recorded as a
  decision

#### Scenario: Acknowledgement does not bypass validity checks
- **WHEN** an acknowledged confirmation is missing a field required to create a subscription, such as
  an amount or a billing cycle
- **THEN** the request fails with an explicit validation error rather than being applied incomplete

### Requirement: A warning names its reason in terms the user can act on
A staleness warning SHALL carry both a stable machine-readable reason and human-readable text stating
what the evidence showed. The text SHALL describe the evidence, not the internal lifecycle state.

#### Scenario: Prior cancellation evidence is named
- **WHEN** the most recent evidence for a merchant is a cancellation later than any paid renewal
- **THEN** the warning says a cancellation was the last thing seen for that merchant, and the user
  can still proceed

#### Scenario: A suppressed merchant is named as the user's own earlier choice
- **WHEN** the user previously chose to stop receiving suggestions for this merchant
- **THEN** the warning attributes it to that earlier choice rather than to missing evidence

#### Scenario: Warning text never leaks raw email content
- **WHEN** any warning is produced
- **THEN** its text is composed from typed fields and fixed copy only, preserving the existing
  anti-exfiltration boundary

### Requirement: The evidence considered includes what the user can see
When deciding whether to warn, the server SHALL consider the merged candidate's fields and the edits
submitted with the confirmation alongside the stored evidence records. A warning SHALL NOT be issued
for the absence of a value that the candidate or the user's edits supply.

#### Scenario: A card completed by merged evidence does not trigger a warning
- **WHEN** a candidate's own amount, currency, billing cycle, and renewal date describe a current
  paid subscription, but the single evidence record backing it lacks those fields
- **THEN** no staleness warning is issued on the grounds of missing recurrence evidence

#### Scenario: A user-supplied amount counts as evidence
- **WHEN** a user types a missing amount into the review sheet and confirms
- **THEN** the submitted value is considered, and the confirmation is not warned for a missing amount

#### Scenario: Genuine contradiction still warns
- **WHEN** the evidence records show a cancellation more recent than any renewal, regardless of what
  the card's fields say
- **THEN** a warning is still issued, because the concern is contradiction rather than absence
