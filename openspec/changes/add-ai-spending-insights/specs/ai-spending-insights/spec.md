## ADDED Requirements

### Requirement: Structured insight generation
The system SHALL generate subscription insights only from a server-built, user-scoped fact bundle containing stored subscription, billing-event, scan-run, and spending-snapshot data. The system MUST NOT include raw email bodies, subjects, senders, OAuth tokens, or unbounded free-text evidence in the insight-generation request.

#### Scenario: Generate an insight report
- **WHEN** an authenticated user refreshes Insights with eligible subscription data
- **THEN** the server SHALL calculate a bounded fact bundle, generate a structured report, and persist it for that user only

#### Scenario: User has no eligible data
- **WHEN** an authenticated user requests insights without active subscriptions or relevant billing data
- **THEN** the system SHALL return a no-insights state without calling the AI provider

### Requirement: Evidence-backed AI cards
The system SHALL render AI-generated summaries and cards only when their referenced subscriptions or billing events belong to the requesting user and their stated amounts and dates match server-calculated facts.

#### Scenario: Model returns an unsupported claim
- **WHEN** the generated response references data absent from the fact bundle or has an invalid schema
- **THEN** the system SHALL discard the invalid AI content and return deterministic insights without exposing the claim

### Requirement: Cached and resilient insight delivery
The system SHALL reuse a valid cached report when its fact fingerprint is unchanged, and Insights MUST remain usable with deterministic content when generation fails or is unavailable.

#### Scenario: Cached report is current
- **WHEN** the user opens Insights and an unexpired report has the current fact fingerprint
- **THEN** the system SHALL return the cached report without a new model request

#### Scenario: AI provider is unavailable
- **WHEN** structured insight generation fails
- **THEN** the user SHALL still see available graphs and a neutral message that AI insights can be retried

