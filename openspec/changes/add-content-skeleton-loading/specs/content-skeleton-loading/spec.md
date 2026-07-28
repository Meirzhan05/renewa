## ADDED Requirements

### Requirement: Accessible shared skeleton placeholders
The app SHALL provide reusable skeleton placeholders styled with Renewa’s established background, surface, and divider palette. Skeleton blocks SHALL use the same broad geometry as the content they represent and SHALL not use a high-contrast or fast sweeping shimmer.

#### Scenario: Placeholder is rendered for known content
- **WHEN** a screen is waiting for content whose final layout is known
- **THEN** the screen SHALL render skeleton blocks shaped and spaced like that content

#### Scenario: Reduce Motion is enabled
- **WHEN** the user enables Reduce Motion
- **THEN** skeleton placeholders SHALL remain static and SHALL not run a nonessential pulse or shimmer animation

#### Scenario: VoiceOver is active during loading
- **WHEN** a skeleton region is visible
- **THEN** decorative skeleton blocks SHALL be hidden from accessibility and the region SHALL expose a concise loading status

### Requirement: Insights initial-load skeleton
The Insights screen SHALL show an Insights-specific skeleton layout while its first deterministic dataset and report request are unresolved. The layout SHALL include placeholders for the commitment summary, insight summary, spending trend, category visualization, and renewal section.

#### Scenario: First Insights load is slow
- **WHEN** the user opens Insights and the initial load exceeds the placeholder presentation delay
- **THEN** Insights SHALL show its layout-matched skeleton instead of an indeterminate page spinner

#### Scenario: Deterministic Insights data becomes available
- **WHEN** subscription-derived chart data becomes available before an AI report finishes
- **THEN** Insights SHALL render available charts and deterministic content while retaining a loading state only for the unresolved insight summary

### Requirement: Progressive refresh feedback
The app SHALL retain successfully loaded content while a user-initiated refresh is running and SHALL communicate the updating state without replacing that content with a full-page skeleton.

#### Scenario: Insights refresh with existing report
- **WHEN** the user refreshes Insights after a prior report has loaded
- **THEN** the prior report and charts SHALL remain visible and the screen SHALL identify that Insights is updating

#### Scenario: Refresh request fails
- **WHEN** a refresh fails after content was previously loaded
- **THEN** the previously loaded content SHALL remain visible and the app SHALL present the failure using its existing error treatment

### Requirement: Subscription collection initial-load placeholder
The overview subscription collection SHALL show a finite set of subscription-row skeletons only while an initial collection load is unresolved and no subscription content is available.

#### Scenario: Subscription rows are initially loading
- **WHEN** the overview collection is awaiting its first response and has no existing subscriptions to display
- **THEN** the screen SHALL render row placeholders that match the subscription card structure

#### Scenario: Collection is genuinely empty
- **WHEN** the initial collection request completes with no subscriptions
- **THEN** the screen SHALL show its empty state and SHALL not continue displaying subscription skeletons

### Requirement: Explicit primary-action progress feedback
Primary actions that submit data or invoke a scan SHALL preserve their button geometry and display task-specific in-button progress text while the action is pending. The action SHALL be disabled until completion and SHALL not rely solely on a generic spinner.

#### Scenario: User submits an authentication form
- **WHEN** sign-in or account creation is pending
- **THEN** the originating button SHALL be disabled and SHALL identify the relevant in-progress action

#### Scenario: User saves or scans from another flow
- **WHEN** onboarding, subscription creation, profile changes, logo selection, account deletion, or email scanning is pending
- **THEN** the originating action button SHALL remain in place and SHALL display task-specific progress feedback

### Requirement: Honest non-loading states
The app SHALL use skeletons only for an unresolved expected content load. It SHALL retain distinct empty, failure, and confirmation states.

#### Scenario: No content exists
- **WHEN** the app knows that a content collection is empty
- **THEN** it SHALL display explanatory empty-state content rather than a skeleton

#### Scenario: A request has failed
- **WHEN** a content request fails and no prior data is available
- **THEN** it SHALL display a comprehensible failure state rather than a skeleton that implies the request is still pending
