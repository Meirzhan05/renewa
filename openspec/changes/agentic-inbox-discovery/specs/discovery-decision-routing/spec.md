## ADDED Requirements

### Requirement: Grounding verification pass

Before a merchant assessment is routed, the system SHALL run a verification pass that checks
each asserted field against the merchant's evidence. Any field not supported by evidence
SHALL be dropped or downgraded, and an assessment whose core existence claim fails
verification SHALL be treated as low-existence. Verification SHALL be the safeguard that
allows the reasoner to assert fields more freely without lowering precision.

#### Scenario: Ungrounded field is stripped before routing
- **WHEN** an assessment asserts a billing cycle that the verification pass cannot ground in
  the evidence
- **THEN** the cycle SHALL be removed and the merchant SHALL be routed as if the cycle were
  missing

#### Scenario: Unsupported existence claim is downgraded
- **WHEN** verification cannot ground the claim that a merchant is an active paid
  subscription
- **THEN** the merchant SHALL be routed as low-existence (watch/ignore), not presented

### Requirement: Two-axis confidence-ladder routing

The system SHALL route each verified merchant assessment on two axes — existence confidence
and completeness — as follows: high existence AND complete SHALL present a candidate for
confirmation; high existence AND incomplete SHALL raise a single clarification for the
missing field; low existence SHALL be recorded as a watch/near-miss and SHALL NOT prompt the
user. Routing SHALL never auto-track a subscription on any path.

#### Scenario: Strong-but-incomplete merchant asks one clarification
- **WHEN** a merchant is verified high-existence with `billing_cycle` missing
- **THEN** the system SHALL raise a `billing_cycle_check` clarification for that merchant
  rather than filing it as "no action"

#### Scenario: Complete merchant is presented for confirmation
- **WHEN** a merchant is verified high-existence and complete
- **THEN** the system SHALL present it as a candidate the user confirms

#### Scenario: Weak signal does not nag the user
- **WHEN** a merchant is verified low-existence
- **THEN** it SHALL be recorded as a near-miss and SHALL NOT surface a confirmation or
  clarification prompt

### Requirement: Human-confirmation gate and deterministic lifecycle preserved

Every path that reaches the user SHALL still require explicit human confirmation before a
subscription is tracked or changed; no routing outcome SHALL add, modify, or end a tracked
subscription on its own. The deterministic merchant-lifecycle reconciliation
(`current`/`ended`/`uncertain`) SHALL remain the source of truth for lifecycle state and
SHALL be fed by the verified assessment.

#### Scenario: Presented candidate is not tracked until confirmed
- **WHEN** the system presents a candidate or asks a clarification
- **THEN** no subscription SHALL be created or changed until the user confirms

### Requirement: Persist near-misses and abstain reasons

The system SHALL persist near-misses and abstain reasons (merchant, existence/completeness
outcome, missing fields, and reason) instead of discarding them, so that "we saw this
merchant but could not confirm it" is recoverable for transparency and debugging.

#### Scenario: A low-existence merchant leaves a trace
- **WHEN** a merchant is routed as a low-existence near-miss
- **THEN** a near-miss record SHALL be persisted capturing the merchant and the reason it
  was not surfaced

#### Scenario: An abstaining assessment records why
- **WHEN** the reasoner abstains on a merchant
- **THEN** its abstain reason SHALL be persisted rather than thrown away
