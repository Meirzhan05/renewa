## ADDED Requirements

### Requirement: Every evidence record carries a canonical merchant identity
When the agent bridge writes a proposal into `detected_billing_events`, that row SHALL carry the
proposal's resolved canonical merchant key. The bridge SHALL NOT write an evidence record with a null
merchant key.

#### Scenario: A newly bridged proposal writes a keyed evidence record
- **WHEN** the bridge writes a proposal whose evidence sender resolves to the identity `anthropic`
- **THEN** the inserted `detected_billing_events` row has `canonical_merchant_key = 'anthropic'`

#### Scenario: A proposal with no resolvable sender still writes a key
- **WHEN** a proposal's evidence sender is absent or unparseable, so identity falls back to the
  display name or the `unknown-merchant` sentinel
- **THEN** the evidence record still carries that fallback key rather than a null

#### Scenario: The written key satisfies the column constraint
- **WHEN** any identity produced by merchant identity resolution is written to an evidence record
- **THEN** the value matches the column's existing pattern constraint and the insert succeeds

### Requirement: An evidence record and the card it backs share one identity
The canonical merchant key on a `detected_billing_events` row SHALL be the same value written to the
`subscription_candidates` row produced from the same proposal. Identity SHALL be resolved once per
proposal and used for both writes, so the two records cannot diverge.

#### Scenario: Both rows agree for one proposal
- **WHEN** one proposal produces an evidence record and a review card
- **THEN** both rows carry an identical `canonical_merchant_key`

#### Scenario: Two display names for one sender agree on both rows
- **WHEN** two proposals from the same registrable sender domain carry the display names `Anthropic`
  and `Anthropic (Claude Pro)`
- **THEN** both evidence records and the single merged review card all carry the same key

#### Scenario: Aggregator fallback is applied consistently
- **WHEN** a proposal's evidence sender is a shared billing processor, so identity falls back to the
  display name
- **THEN** the evidence record carries that name-derived key, matching the card, and not a key
  derived from the processor's domain

### Requirement: Re-scanning an unkeyed evidence record repairs it
The evidence upsert SHALL set the canonical merchant key on conflict as well as on insert, so an
evidence record written before this capability existed gains its identity the next time the agent
derives the same event. Repair SHALL occur only through the normal scan path; no bulk rewrite of
existing rows is performed.

#### Scenario: A pre-existing unkeyed row is repaired by a later scan
- **WHEN** a later scan re-derives an event that already exists with a null `canonical_merchant_key`
- **THEN** the conflict branch writes the resolved identity onto that existing row

#### Scenario: Repair does not disturb the record's grain
- **WHEN** the conflict branch updates an existing evidence record
- **THEN** the row's natural key `(user_id, provider, provider_message_id, event_type)` is unchanged
  and no duplicate evidence record is created

#### Scenario: Rows never re-derived are left alone
- **WHEN** an evidence record's source email falls outside every later scan window
- **THEN** that row keeps its null key and no migration rewrites it

### Requirement: Merchant history reconstructed from evidence finds the agent's records
Consumers that reconstruct a merchant's history by selecting evidence records on canonical merchant
key SHALL find the records the agent wrote for that merchant.

#### Scenario: The confirm-time lifecycle lookup matches agent evidence
- **WHEN** merchant lifecycle is reconstructed for a candidate whose key is `anthropic`, and the
  agent has written evidence records for `anthropic`
- **THEN** the lookup returns those records instead of an empty set

#### Scenario: A complete paid-recurring record yields a current lifecycle
- **WHEN** the most recent paid-recurring evidence record for a merchant carries an amount, a
  currency, a billing cycle, and a renewal date at or after today, with no later ending event
- **THEN** the reconstructed lifecycle state is `current`

#### Scenario: The learning summary sees agent evidence
- **WHEN** the learning summary joins evidence records to merchant evidence bundles by canonical
  merchant key
- **THEN** agent-written records are eligible to appear rather than being silently excluded
