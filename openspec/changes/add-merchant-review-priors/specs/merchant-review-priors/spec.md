## ADDED Requirements

### Requirement: Learn field priors from review outcomes

The system SHALL derive a per-user, per-merchant prior for a supported field when the person
confirms or corrects a discovery candidate. Supported fields SHALL be limited to `billing_cycle`
and `category` in this change. A prior SHALL be keyed by `(user_id, canonical_merchant_key,
field)` and SHALL record the learned value and an evidence strength derived from how many
consistent outcomes support it.

#### Scenario: Correction records a prior
- **WHEN** a person changes a candidate's proposed billing cycle from `monthly` to `yearly` and confirms
- **THEN** the system stores a `billing_cycle` prior of `yearly` for that user and merchant with evidence strength reflecting one supporting outcome

#### Scenario: Confirmation without change reinforces a prior
- **WHEN** a person confirms a candidate whose category already matches an existing prior
- **THEN** the system increases the evidence strength of that prior rather than creating a duplicate

#### Scenario: Conflicting corrections weaken a prior
- **WHEN** a person previously corrected a merchant to `yearly` and later corrects the same merchant to `monthly`
- **THEN** the system updates the prior to the most recent value and does not retain the superseded value as authoritative

#### Scenario: Unsupported fields are not learned
- **WHEN** a person corrects a candidate's amount or merchant name
- **THEN** the system does not create a `billing_cycle` or `category` prior from that field and stores no prior for the unsupported field

### Requirement: Persist billing-cycle clarification answers as priors

The system SHALL persist a durable `billing_cycle` prior when a person answers a billing-cycle
clarification with a concrete cadence, in addition to unblocking the single candidate that
prompted the clarification.

#### Scenario: Cycle clarification answer becomes a prior
- **WHEN** a person answers a billing-cycle clarification for a merchant with `yearly`
- **THEN** the system stores a `billing_cycle` prior of `yearly` for that user and merchant so future scans do not re-ask the same question

#### Scenario: "Not sure" answer records no prior
- **WHEN** a person answers a billing-cycle clarification with `not_sure`
- **THEN** the system records no `billing_cycle` prior for that merchant

### Requirement: Pre-fill learned fields during a scan

During a scan, after extraction and identity resolution and before a candidate is created, the
system SHALL overlay the person's stored priors for the resolved merchant onto fields the model
left null or did not determine. Overlaying a prior SHALL be treated as a proposed default that
still requires human confirmation.

#### Scenario: Prior fills a missing billing cycle
- **WHEN** a scan extracts a paid recurring event for a merchant whose `billing_cycle` the model left null, and a `billing_cycle` prior exists for that user and merchant
- **THEN** the resulting candidate uses the prior's billing cycle and no billing-cycle clarification is raised

#### Scenario: Prior does not overwrite model-provided values
- **WHEN** the model returns a concrete `billing_cycle` for an event and a differing prior exists
- **THEN** the candidate keeps the model's extracted value and the prior is not applied

#### Scenario: No prior leaves behavior unchanged
- **WHEN** a scan extracts an event for a merchant with no stored priors
- **THEN** the candidate and clarification behavior is identical to the pre-change pipeline

### Requirement: Suppress already-answered clarifications

The system SHALL NOT raise a clarification for a field when a stored prior for that user, merchant,
and field already resolves the ambiguity that the clarification would ask about.

#### Scenario: Answered cycle question is not re-asked
- **WHEN** a person has a stored `billing_cycle` prior for a merchant and a later scan finds a credible charge with an unclear cadence for the same merchant
- **THEN** the system applies the prior and does not raise a billing-cycle clarification

### Requirement: Fresh billing evidence overrides priors

Priors SHALL be defaults only. When the scan's own evidence is authoritative for a field, the
system SHALL prefer the fresh evidence over any stored prior. An explicit price change or
cancellation event SHALL always take precedence over a stored prior.

#### Scenario: Price change overrides a stored amount-adjacent default
- **WHEN** a scan extracts a `price_changed` event for a merchant that has stored priors
- **THEN** the system uses the event's fresh values and lifecycle handling, and does not let priors mask the price change

#### Scenario: Cancellation is never blocked by a prior
- **WHEN** a scan reconciles a merchant lifecycle to ended based on an explicit cancellation
- **THEN** priors do not reintroduce the merchant as current or suppress the cancellation candidate

### Requirement: Preserve the human confirmation gate

Applying a prior SHALL NOT change a subscription on its own. Every addition, update, or
cancellation SHALL still require explicit authenticated confirmation, exactly as before this
change.

#### Scenario: Pre-filled candidate still requires confirmation
- **WHEN** a candidate has a field pre-filled from a prior
- **THEN** the subscription is unchanged until the person confirms the candidate

### Requirement: Scope priors to the owning user

Priors SHALL be private to the user who generated them. The system SHALL store priors only from a
person's own confirmed or corrected outcomes and SHALL enforce row-level ownership so no other
authenticated user can read or write them. Priors SHALL store only derived field values, never raw
email content.

#### Scenario: Another user cannot read priors
- **WHEN** a different authenticated user queries priors they do not own
- **THEN** row-level security returns no rows

#### Scenario: Account deletion removes priors
- **WHEN** a person's account is deleted
- **THEN** their stored priors are removed as part of the deletion cascade
