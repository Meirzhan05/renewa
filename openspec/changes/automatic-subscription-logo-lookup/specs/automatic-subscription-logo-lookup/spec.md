## ADDED Requirements

### Requirement: Automatic subscription-name logo lookup
The system SHALL attempt a Logo.dev name-based image lookup for every non-empty subscription without a reviewed brand identifier. The request MUST preserve the current transparent image format, presentation cache version, and local fallback behavior.

#### Scenario: Unknown manual subscription receives a logo
- **WHEN** a user enters a non-empty subscription name with no reviewed catalog match
- **THEN** the app attempts a Logo.dev name-based logo lookup for its preview and saved row

#### Scenario: Name lookup has no logo
- **WHEN** Logo.dev returns no image or the device is offline for an unknown subscription
- **THEN** the app displays the subscription's local initial fallback without an error state

### Requirement: Verified domain precedence
The system SHALL use the reviewed verified-domain image request instead of name lookup whenever a subscription has a catalogued `brand_id`.

#### Scenario: Reviewed subscription is displayed
- **WHEN** a subscription has a `brand_id` that maps to a reviewed domain
- **THEN** the app uses that domain's Logo.dev image request and does not use its name-based request

### Requirement: Reversible automatic logo result
The system SHALL preserve the user's ability to choose a reviewed brand or clear the brand choice after an automatic name-based lookup. Automatic name matches MUST NOT be persisted as reviewed brand identifiers.

#### Scenario: User replaces an automatic result
- **WHEN** a user changes the logo for a subscription with no reviewed brand identifier
- **THEN** the chosen reviewed brand or fallback replaces the automatic name-based presentation according to the saved `brand_id`
