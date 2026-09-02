## MODIFIED Requirements

### Requirement: A deterministic dedup guard enforces idempotency
The `propose` write SHALL apply a deterministic dedup guard that rejects a proposal exact-matching an
item the user already tracks or has already rejected/suppressed. This guard is idempotency plumbing,
not subscription judgment.

The guard SHALL match on resolved merchant identity rather than on the model-chosen display name, so
that two proposals for one vendor are recognised as duplicates even when the model labelled them
differently. Because pages of a run are analysed concurrently and share no in-process state, the
guard SHALL NOT rely on in-memory state alone for correctness: the durable write boundary SHALL be
the authoritative point at which a duplicate is collapsed.

#### Scenario: Duplicate proposal is dropped at the write
- **WHEN** the agent proposes a merchant that exactly matches an already-tracked subscription
- **THEN** the dedup guard drops the proposal before it reaches the human queue

#### Scenario: Re-run yields no duplicate proposals
- **WHEN** the same inbox is scanned twice with no new evidence
- **THEN** the second run enqueues no proposals that duplicate the first run's confirmed or rejected items

#### Scenario: Differing display names for one vendor are recognised as duplicates
- **WHEN** the agent proposes `Anthropic` from one email and `Anthropic (Claude Pro)` from another,
  both billed by the same vendor
- **THEN** the guard treats them as the same merchant and the human queue receives one item

#### Scenario: A suppressed merchant stays suppressed under a new label
- **WHEN** a user has suppressed a merchant and a later scan proposes that same vendor under a
  different display name
- **THEN** the guard recognises the suppression and does not re-surface the merchant

#### Scenario: Duplicates across concurrently analysed pages are collapsed
- **WHEN** two pages of one run independently propose the same merchant and neither can observe the
  other's in-memory state
- **THEN** the durable write boundary collapses them into a single queued item
