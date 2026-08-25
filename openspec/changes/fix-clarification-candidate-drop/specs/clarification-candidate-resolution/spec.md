## ADDED Requirements

### Requirement: Renewal date is projected from the billing cycle, not required from the email
The system SHALL treat a subscription's `renewal_date` as a derived value, computed from the last
charge date plus the billing cycle, and SHALL NOT require an email to contain an explicit renewal
date in order to create a candidate. When resolving a clarification that establishes the billing
cycle, the system SHALL project `renewal_date` before evaluating candidate admission.

#### Scenario: Receipt without an explicit renewal date, cycle clarified
- **WHEN** a detected billing event has an amount and currency but no renewal date, and the user
  answers a billing-cycle clarification with "monthly"
- **THEN** the system projects `renewal_date` as the event's charge date plus one month
- **AND** the resulting candidate is admitted (a missing renewal date does not block it)

#### Scenario: Email that does state a renewal date
- **WHEN** the detected billing event already carries a renewal date
- **THEN** the system SHALL keep that stated renewal date rather than overwriting it with a
  projection

### Requirement: A user's clarification answer counts as confident evidence
The system SHALL treat a candidate created from a user's clarification answer as human-confirmed,
so the automatic-detection confidence floor used for machine-detected events does not, by itself,
cause the clarified candidate to be dropped.

#### Scenario: Low model confidence but a human answer
- **WHEN** a detected billing event has model confidence below the auto-detection floor, and the
  user answers its clarification affirmatively (a cycle, or "yes")
- **THEN** the confidence floor does not exclude the candidate
- **AND** a reviewable candidate is created

### Requirement: Answering an actionable clarification yields a reviewable candidate
The system SHALL, when a user answers an actionable clarification (a billing cycle, or an
affirmative lifecycle answer) for an event with a known amount and currency, produce a
subscription candidate in the review queue that still requires the user's confirmation to become a
tracked subscription.

#### Scenario: Anthropic cycle clarified
- **WHEN** the user answers "How often do you pay for Anthropic?" with "Monthly", and the event has
  an amount and currency
- **THEN** an Anthropic candidate appears in "Needs your review" with a "Track it" / "Not mine"
  choice
- **AND** the candidate is not auto-tracked without the user's confirmation

### Requirement: A clarification is never silently consumed without an outcome
The system SHALL NOT mark a clarification resolved as "candidate unblocked" unless a candidate was
actually created. When the resolution path cannot create a candidate, the system SHALL either leave
the clarification recoverable or record an explicit non-actionable outcome — it MUST NOT both
consume the question and produce nothing.

#### Scenario: Resolution path produces no candidate
- **WHEN** the user answers a clarification but candidate creation does not occur (any reason)
- **THEN** the clarification is NOT recorded with a "candidate unblocked" effect
- **AND** the question does not silently disappear leaving no candidate and no recorded reason

#### Scenario: Successful candidate creation
- **WHEN** the user answers a clarification and a candidate is created
- **THEN** the clarification is marked resolved and does not reappear
