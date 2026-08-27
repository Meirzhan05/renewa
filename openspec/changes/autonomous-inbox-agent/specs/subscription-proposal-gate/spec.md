## ADDED Requirements

### Requirement: Propose is the only write, and it writes a proposal
The agent's sole side-effecting tool SHALL be `propose`, which enqueues a subscription *proposal* —
never a subscription. Nothing SHALL mutate the user's subscription list without an explicit human
confirmation.

#### Scenario: A proposal does not change the subscription list
- **WHEN** the agent calls `propose`
- **THEN** a proposal is enqueued and the subscription list is unchanged until a human confirms

### Requirement: Proposal fields are typed and carry no free text
A proposal SHALL contain only typed, bounded fields (enums for cycle/category/event-type, numbers
for amounts, ISO dates, a merchant name from a bounded set of observed values). It SHALL NOT contain
free-text notes or any field into which untrusted email content can be smuggled to a human reader.

#### Scenario: Free-text smuggling is rejected
- **WHEN** the agent attempts to attach an unbounded free-text field to a proposal
- **THEN** the field is rejected by schema validation and does not reach the human-facing card

#### Scenario: Out-of-range field is rejected
- **WHEN** a proposed amount, enum, or date fails validation
- **THEN** the proposal is rejected or the offending field is dropped before enqueue

### Requirement: A deterministic dedup guard enforces idempotency
The `propose` write SHALL apply a deterministic dedup guard that rejects a proposal exact-matching an
item the user already tracks or has already rejected/suppressed. This guard is idempotency plumbing,
not subscription judgment.

#### Scenario: Duplicate proposal is dropped at the write
- **WHEN** the agent proposes a merchant that exactly matches an already-tracked subscription
- **THEN** the dedup guard drops the proposal before it reaches the human queue

#### Scenario: Re-run yields no duplicate proposals
- **WHEN** the same inbox is scanned twice with no new evidence
- **THEN** the second run enqueues no proposals that duplicate the first run's confirmed or rejected items

### Requirement: The human confirms, edits, or rejects every proposal
Each proposal SHALL be resolved by a human as confirm, edit-then-confirm, or reject before it can
affect the subscription list.

#### Scenario: Confirm creates the subscription
- **WHEN** a user confirms a proposal
- **THEN** the corresponding subscription is created or updated

#### Scenario: Reject creates no subscription
- **WHEN** a user rejects a proposal
- **THEN** no subscription is created and the rejection is recorded

### Requirement: Human responses feed cross-run learning
Confirmations, edits, and rejections SHALL be persisted as durable priors (learned field values,
aliases) and suppressions that the agent consults on later scans, closing the loop across runs.

#### Scenario: An edit is learned as a prior
- **WHEN** a user edits a proposed billing cycle before confirming
- **THEN** the corrected value is stored as a prior and pre-fills the same merchant on the next scan

#### Scenario: A rejection becomes a suppression
- **WHEN** a user rejects a proposal
- **THEN** the merchant is recorded as suppressed and the agent avoids re-proposing it next scan
