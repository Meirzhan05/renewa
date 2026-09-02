## ADDED Requirements

### Requirement: One pending review card per merchant identity per user
The review queue SHALL contain at most one PENDING `subscription_candidates` row for a given
`(user_id, canonical_merchant_key)` pair. Additional proposals resolving to a merchant identity that
already has a pending card SHALL merge into that card instead of creating another one. The scope is
the user's pending queue rather than a single scan run, because that is the set the inbox displays:
it selects candidates by user and review status without filtering by run.

#### Scenario: Second proposal for a known merchant merges
- **WHEN** a pending card exists for a merchant identity and another page proposes the same identity
- **THEN** no second card is created and the user's pending card count for that merchant remains one

#### Scenario: A later scan does not stack another card
- **WHEN** a subsequent scan run proposes a merchant that already has a pending card from an earlier
  run
- **THEN** the existing card is updated rather than joined by a second card

#### Scenario: The user sees one card per subscription
- **WHEN** a scan produces evidence for one subscription across several billing emails
- **THEN** the review queue presents a single card for that subscription

#### Scenario: A resolved card does not block a later proposal
- **WHEN** a merchant's card has been confirmed or ignored and a later scan proposes that merchant
- **THEN** the rollup permits a new pending card, leaving whether it should reappear to the
  suppression rules rather than to this constraint

### Requirement: Merging prefers the most confident evidence and fills gaps
When a proposal merges into an existing card, the merge SHALL be deterministic: a field held by the
higher-confidence proposal wins, and a field that is null on the existing card SHALL be filled from
the incoming proposal. Merging SHALL NOT overwrite a populated field with a null.

#### Scenario: Higher-confidence proposal supplies the card's fields
- **WHEN** an incoming proposal for an existing identity carries higher confidence than the card
- **THEN** the card adopts that proposal's merchant name, amount, currency, and billing cycle

#### Scenario: A null does not erase a known value
- **WHEN** an incoming proposal has a null amount and the existing card has an amount
- **THEN** the card retains its amount

#### Scenario: A gap is filled from lower-confidence evidence
- **WHEN** the existing card has no billing cycle and a lower-confidence proposal supplies one
- **THEN** the card adopts the supplied billing cycle

### Requirement: The rollup is enforced by the database, not only by application logic
Uniqueness of `(user_id, canonical_merchant_key)` among pending review cards SHALL be enforced by a
database constraint, so that pages analysed concurrently and without shared in-process state cannot
race duplicate cards into the queue.

#### Scenario: Concurrent pages cannot double-insert
- **WHEN** two pages of the same run resolve the same merchant identity at the same time
- **THEN** exactly one card exists for that identity after both pages complete, and neither page
  fails

#### Scenario: Re-running a page does not duplicate
- **WHEN** a page is retried after a failure and re-proposes merchants it already proposed
- **THEN** the run's review queue is unchanged in card count

### Requirement: Evidence records keep their per-email grain
Rolling up the review queue SHALL NOT change how billing evidence is recorded. Each analysed email
SHALL continue to produce its own `detected_billing_events` row under the existing conflict key, so
that several evidence records may reference one review card.

#### Scenario: Multiple evidence rows behind one card
- **WHEN** three billing emails from one vendor are analysed in a run
- **THEN** three evidence records exist and one review card references that merchant identity

#### Scenario: Evidence conflict key is unchanged
- **WHEN** the same email is analysed twice
- **THEN** it upserts onto its existing evidence row exactly as before

### Requirement: Colliding pending cards are consolidated before the constraint applies
Pending cards that already collide under `(user_id, canonical_merchant_key)` SHALL be consolidated
into one surviving card so the uniqueness constraint can be applied without losing a user-visible
pending review. Cards written before this change keep their previously derived merchant keys and are
NOT re-identified; duplicates that differ by key therefore remain until the user resolves them, and
consolidation SHALL NOT alter any card the user has already resolved.

#### Scenario: Colliding pending cards collapse
- **WHEN** the change is deployed against data where one merchant identity has two pending cards
- **THEN** those rows are merged into a single surviving card carrying the merged field values

#### Scenario: Resolved decisions are preserved
- **WHEN** consolidating alongside cards the user has already confirmed or ignored
- **THEN** those recorded decisions are left untouched

#### Scenario: Pre-existing differently-keyed duplicates are left in place
- **WHEN** older cards for one vendor were stored under different merchant keys
- **THEN** they are not merged or re-keyed, and later scans surface that vendor as a single card
