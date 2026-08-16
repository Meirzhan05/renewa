## ADDED Requirements

### Requirement: Merchant-local evidence bundles
The system SHALL assemble validated billing events into user-owned merchant evidence bundles before evaluating lifecycle or creating a discovery candidate. A bundle SHALL retain links to its supporting events and a non-sensitive resolution reason, but MUST NOT retain raw email bodies or raw model payloads.

#### Scenario: Events resolve to the same merchant
- **WHEN** two validated events resolve to the same user-owned merchant identity
- **THEN** the system evaluates their ordered evidence together and links both events to the resulting bundle

#### Scenario: An event has unresolved identity
- **WHEN** an event cannot be resolved to exactly one merchant identity
- **THEN** the system retains the event without adding it to an actionable bundle or creating an action candidate

### Requirement: Deterministic merchant identity resolution
The system SHALL resolve merchant identity using server-owned canonical keys, reviewed aliases, recognized brands, and verified sender-domain evidence. It MUST return ambiguity when more than one identity is supported and MUST NOT use a model-reported subscription identifier.

#### Scenario: A reviewed alias resolves an event
- **WHEN** an event's normalized merchant label matches one reviewed alias owned by the user
- **THEN** the system resolves the event to that merchant identity with the alias as its reason

#### Scenario: Competing identities match
- **WHEN** more than one user-owned merchant identity is supported by the same event
- **THEN** the system marks the identity ambiguous and withholds an actionable proposal

### Requirement: Bounded advisory identity adjudication
The system MAY request an advisory adjudication only for an explicitly supported deterministic identity or evidence conflict. The request SHALL contain only bounded, privacy-minimized event summaries, and the response MUST be runtime-validated as `same_merchant`, `different_merchant`, or `abstain` before server-owned policy considers it.

#### Scenario: Eligible ambiguity receives a valid advisory decision
- **WHEN** a named conflict type is eligible and the adjudicator returns a valid decision referencing only submitted evidence
- **THEN** the system records the versioned advisory result and continues through deterministic lifecycle and review policy

#### Scenario: Advisory output is invalid or abstains
- **WHEN** the adjudicator output is malformed, references unsubmitted evidence, or abstains
- **THEN** the system records no actionable identity resolution and does not retry the adjudication automatically
