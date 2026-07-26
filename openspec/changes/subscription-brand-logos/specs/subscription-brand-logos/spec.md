## ADDED Requirements

### Requirement: Stable brand identification
The system SHALL associate a subscription with an optional stable brand identifier when its service name exactly matches a reviewed catalog alias after normalization. The identifier MUST be independent of any remote logo-provider URL.

#### Scenario: Manual subscription matches a catalog alias
- **WHEN** a user creates a subscription named with a recognized service alias
- **THEN** the system persists that service's stable brand identifier with the subscription

#### Scenario: Unknown subscription has no matching brand
- **WHEN** a user creates a subscription whose normalized name does not match a reviewed alias
- **THEN** the system persists no brand identifier and retains the existing icon-name and tint fallback data

### Requirement: Consistent email-discovered brand resolution
The system SHALL apply the same reviewed alias catalog to email-discovered merchant names before saving or updating a subscription.

#### Scenario: Email event matches a known merchant
- **WHEN** a confidence-qualified email event identifies a merchant matching a reviewed alias
- **THEN** the saved subscription contains the matching stable brand identifier

#### Scenario: Email event does not match a merchant
- **WHEN** a confidence-qualified email event identifies an unknown or ambiguous merchant
- **THEN** the saved subscription contains no brand identifier and remains usable with the fallback icon

### Requirement: Resilient brand-logo presentation
The system SHALL render a Logo.dev logo when a configured provider request succeeds. It MUST render the existing colored initial tile whenever the provider image is unavailable, and it MUST NOT delay rendering the subscription row while determining the visual. Both states MUST use the same circular, subtly elevated medallion treatment.

#### Scenario: Recognized subscription displays a logo
- **WHEN** a subscription has a brand identifier with a verified Logo.dev domain and a provider image is available
- **THEN** its subscription row displays that provider image in the standard icon frame

#### Scenario: Existing subscription has no brand identifier
- **WHEN** a subscription created before this capability has no brand identifier
- **THEN** its subscription row displays the existing initial-and-tint icon without an error state

#### Scenario: Provider image is unavailable
- **WHEN** a subscription references a brand identifier with no available Logo.dev image
- **THEN** its subscription row displays the existing initial-and-tint icon

### Requirement: Accessible and reviewed brand catalog
The system SHALL expose the subscription name as the accessibility label for its brand visual. Each reviewed catalog entry MUST map to a verified domain and the system MUST retain Logo.dev attribution information.

#### Scenario: VoiceOver reads a recognized logo
- **WHEN** VoiceOver focuses the visual for a recognized subscription
- **THEN** it announces the subscription name rather than an internal asset or identifier

#### Scenario: A new catalog entry is introduced
- **WHEN** a contributor adds a reviewed catalog entry
- **THEN** the contribution includes its verified domain and retains Logo.dev attribution information

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
- **THEN** Profile displays a Logo.dev attribution link
