## ADDED Requirements

### Requirement: Every review outcome is distinguishable by the client
The review endpoint's response SHALL let a client tell apart every outcome of a decision: applied,
warned and awaiting acknowledgement, ignored at the user's request, already resolved, and failed. A
successful HTTP status SHALL NOT be the only signal a client has.

#### Scenario: An applied confirmation is identifiable
- **WHEN** a confirmation creates or updates a subscription
- **THEN** the response reports the confirmed status together with the applied subscription's
  identifier

#### Scenario: A warned confirmation is identifiable
- **WHEN** a confirmation is returned unapplied because of a staleness warning
- **THEN** the response reports the warning outcome with its reason, and carries no applied
  subscription identifier

#### Scenario: An outcome the client does not recognize is not read as success
- **WHEN** a client receives an outcome value it does not know
- **THEN** it treats the decision as not applied rather than defaulting to success

### Requirement: A decision that did not apply is never reported as saved
The client SHALL NOT report a confirmation as successful unless the response states that a
subscription was applied. A confirmation returning any other outcome SHALL leave the card in place
and tell the user what happened.

#### Scenario: The optimistic collapse is rolled back on a non-applied outcome
- **WHEN** a card is optimistically collapsed on tap and the confirmation returns warned or ignored
- **THEN** the card is restored to the review queue rather than staying collapsed

#### Scenario: The user is told, in the same interaction
- **WHEN** a confirmation does not apply
- **THEN** the user is shown why, without having to reopen the screen or run another scan to notice

#### Scenario: A transport failure and a refusal are distinguished
- **WHEN** the request fails at the network or authentication layer
- **THEN** the user sees a failure message distinct from a server-side refusal to apply

### Requirement: The response body is consumed, not discarded
The client's review call SHALL read the decision response and drive its own state from it. It SHALL
NOT return a success indicator derived solely from the absence of a thrown error.

#### Scenario: Response status drives the client's result
- **WHEN** the server responds that the candidate was ignored in answer to a confirm request
- **THEN** the client's review operation reports not-applied, even though the request itself succeeded

#### Scenario: The applied subscription identifier is used
- **WHEN** a confirmation applies
- **THEN** the client uses the returned applied subscription identifier to verify the refreshed
  subscription list contains it

#### Scenario: An idempotent repeat is not an error
- **WHEN** the server reports the decision was already recorded
- **THEN** the client treats it as settled rather than as a failure, and does not restore the card
