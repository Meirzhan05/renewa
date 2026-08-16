## ADDED Requirements

### Requirement: Evidence-backed discovery proposals
The system SHALL create a subscription discovery proposal only from a resolved merchant evidence bundle that satisfies lifecycle and review policy. A single extracted message MUST NOT independently authorize a proposal when relevant merchant-local evidence is available.

#### Scenario: Later evidence supersedes an earlier receipt
- **WHEN** a merchant bundle contains an earlier recurring receipt and later explicit ending evidence
- **THEN** the system withholds add/update proposals and follows the lifecycle cancellation policy instead

#### Scenario: Current evidence supports a proposal
- **WHEN** a resolved merchant bundle has current lifecycle evidence and is not suppressed
- **THEN** the system creates at most one reviewable proposal linked to the supporting evidence

### Requirement: Constrained ambiguity processing
The discovery worker SHALL invoke an AI adjudicator only for configured ambiguity types after deterministic processing. The adjudicator MUST NOT receive raw email bodies, subscription IDs, tools, or mutation authority.

#### Scenario: An event is not eligible for adjudication
- **WHEN** an event is unresolved but does not match a configured ambiguity type
- **THEN** the worker retains the event and abstains from creating a proposal without calling the adjudicator
