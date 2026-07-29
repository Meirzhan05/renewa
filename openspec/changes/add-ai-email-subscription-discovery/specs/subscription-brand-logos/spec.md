## MODIFIED Requirements

### Requirement: Consistent email-discovered brand resolution
The system SHALL resolve a confirmed email discovery through a provider-independent canonical merchant identity and SHALL apply the reviewed alias catalog before saving or updating its subscription. The AI extractor MUST NOT directly select a brand identifier.

#### Scenario: Confirmed email event matches a known merchant
- **WHEN** the user confirms an email-derived candidate whose deterministic canonical identity matches a reviewed alias
- **THEN** the saved subscription contains the matching stable brand identifier

#### Scenario: Confirmed email event does not match a merchant
- **WHEN** the user confirms an email-derived candidate whose canonical identity is unknown or ambiguous
- **THEN** the saved subscription contains no reviewed brand identifier and remains usable with the fallback icon

#### Scenario: Unreviewed event identifies a merchant
- **WHEN** extraction produces a pending candidate with a possible reviewed alias
- **THEN** no subscription or brand identifier is persisted until the user confirms the candidate

