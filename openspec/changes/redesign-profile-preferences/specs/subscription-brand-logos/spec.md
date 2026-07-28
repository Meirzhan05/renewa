## MODIFIED Requirements

### Requirement: Optional remote logo fallback
When a valid Logo.dev publishable key is configured, the system SHALL request a Logo.dev image for every subscription, using a verified domain for a reviewed brand and name lookup otherwise. It MUST use a provider 404 fallback and MUST preserve Renewa's initial tile during loading, offline operation, and request failure.

#### Scenario: Subscription receives a remote logo
- **WHEN** a subscription is displayed with Logo.dev configured and its domain or name resolves to a provider image
- **THEN** the row replaces the temporary initial tile with the returned logo

#### Scenario: Remote logo is unavailable
- **WHEN** Logo.dev is unavailable, returns no match, or the device is offline
- **THEN** the row continues displaying Renewa's initial-and-tint tile without an error message

#### Scenario: Remote fallback is enabled in a commercial app
- **WHEN** a Logo.dev publishable key is configured
- **THEN** an About or licenses destination reachable from Profile displays a Logo.dev attribution link
