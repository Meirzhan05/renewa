## ADDED Requirements

### Requirement: A subscription created by confirming a card inherits the card's identity
When a confirmation creates or updates a subscription, that subscription SHALL take the candidate's
canonical merchant key. It SHALL NOT derive a separate identity from the display name.

#### Scenario: The created subscription carries the card's key
- **WHEN** a card whose canonical merchant key is `anthropic` and whose display name is
  `Anthropic (Claude Pro)` is confirmed
- **THEN** the created subscription's canonical merchant key is `anthropic`

#### Scenario: The next scan recognizes the confirmed subscription
- **WHEN** a later scan raises a proposal from the same sender domain as a previously confirmed card
- **THEN** the proposal matches the existing subscription and is surfaced as an update rather than as
  a new add

#### Scenario: A renamed subscription keeps its identity
- **WHEN** a user edits the merchant name in the review sheet before confirming
- **THEN** the subscription is stored under the edited display name but keeps the card's merchant
  identity

### Requirement: Every subscription has a resolvable merchant identity, however it was created
Every subscription SHALL have a canonical merchant identity available wherever identity is consumed,
whether or not the stored row carries one. Where the column is unset — as it is for every
subscription created outside the review flow — identity SHALL be derived from the subscription's name
at the point of use. Lookups that consume identity SHALL NOT exclude subscriptions whose key column
is null.

#### Scenario: A manually added subscription is recognized by the agent
- **WHEN** a user adds a subscription by hand and a later scan finds billing evidence for that
  merchant
- **THEN** the proposal matches the manual subscription instead of being surfaced as a new add

#### Scenario: Identity is derived where it is consumed
- **WHEN** a subscription's stored canonical merchant key is null
- **THEN** the reader derives it from the subscription's name rather than skipping the row

#### Scenario: The agent knows what the user already tracks
- **WHEN** the agent is given the user's current subscriptions to reason about
- **THEN** manually added subscriptions are included, not filtered out for lacking a stored key

#### Scenario: One derivation, not three
- **WHEN** identity is derived for a subscription with no stored key
- **THEN** it uses the same derivation as proposals and review cards, with no second implementation
  in SQL or in the client that could drift from it

#### Scenario: A user-chosen name still yields a usable key
- **WHEN** a manually added subscription's name does not correspond to any known sender domain
- **THEN** a name-derived key is produced, stable for that name across scans

### Requirement: A user's tracked subscription is not proposed to them again
Once a merchant is tracked, later evidence for that merchant SHALL be surfaced as an update to the
tracked subscription, not as a new subscription to add.

#### Scenario: Confirming does not lead to a duplicate card
- **WHEN** a card is confirmed and the next scan sees further evidence from the same merchant
- **THEN** the user is not offered a second card proposing to add what they just added

#### Scenario: The match survives differing display names
- **WHEN** the tracked subscription and a later proposal use different display names for one vendor
  billing from the same sender domain
- **THEN** they still match, because matching is by identity rather than by name

#### Scenario: Distinct merchants are not fused by the match
- **WHEN** two tracked subscriptions belong to genuinely different vendors
- **THEN** a proposal matches at most the one sharing its identity, and never both
