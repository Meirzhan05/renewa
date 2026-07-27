## ADDED Requirements

### Requirement: Protected merchant enrichment design boundary
The system SHALL reserve Logo.dev search and transaction-enrichment calls for a server-side component using a protected secret key. The iOS application MUST NOT embed, transmit, or expose a Logo.dev secret key.

#### Scenario: Future email merchant enrichment is configured
- **WHEN** a backend merchant-enrichment integration is added for email-derived subscriptions
- **THEN** it obtains its Logo.dev secret from Supabase server secrets and returns only approved merchant data to the client

#### Scenario: iOS displays an email-derived unknown merchant
- **WHEN** an email-derived subscription has no reviewed brand identifier
- **THEN** the iOS app uses the client-safe presentation lookup or local fallback without invoking a secret-key API
