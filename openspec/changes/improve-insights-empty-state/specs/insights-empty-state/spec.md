## ADDED Requirements

### Requirement: Unified first-time Insights state
The Insights screen SHALL replace its financial summary and visualization stack with one coherent activation state when loading has resolved and the user has no subscriptions, spending snapshots, or insight report. The activation state MUST explain the value of Insights without displaying invented financial values, dates, percentages, or sample chart data.

#### Scenario: User has no insight evidence
- **WHEN** the initial Insights load completes with no subscriptions, snapshots, or insight report
- **THEN** Insights SHALL show the unified activation state and SHALL NOT present a `$0` commitment or a stack of unavailable visualization cards

#### Scenario: Insight evidence is still loading
- **WHEN** Insights has not yet resolved whether subscription, snapshot, or report evidence exists
- **THEN** Insights SHALL retain its loading treatment and SHALL NOT briefly present the activation state

#### Scenario: Retained evidence exists without active subscriptions
- **WHEN** the user has an inactive subscription, persisted snapshot, or retained insight report but no active subscription
- **THEN** Insights SHALL preserve the normal evidence-based dashboard and SHALL NOT treat the user as a first-time account

### Requirement: Contextual activation actions
The unified activation state SHALL provide actions to open the existing manual add-subscription flow and to continue to the Inbox discovery experience.

#### Scenario: User chooses manual entry
- **WHEN** the user activates the add-subscription action from the Insights empty state
- **THEN** the app SHALL present the existing add-subscription flow

#### Scenario: User chooses inbox discovery
- **WHEN** the user activates the inbox-discovery action from the Insights empty state
- **THEN** the app SHALL select the Inbox experience

#### Scenario: Empty account views Insights
- **WHEN** the unified activation state is visible
- **THEN** Insights SHALL prioritize its activation actions and SHALL NOT present refresh as the primary path to creating insight evidence

### Requirement: Honest commitment completeness
Insights SHALL distinguish absent active commitments from totals whose currency conversion is complete, partial, or unavailable. It MUST NOT present an absent or wholly unconvertible commitment as a verified zero total.

#### Scenario: No active subscriptions with retained evidence
- **WHEN** retained insight evidence exists but no subscription is active
- **THEN** the commitment area SHALL state that there are no current commitments while preserving available historical content

#### Scenario: Every active subscription is convertible
- **WHEN** every active subscription can be represented in the selected display currency
- **THEN** Insights SHALL present the complete monthly and annual commitment in that currency

#### Scenario: Some active subscriptions are not convertible
- **WHEN** a commitment total excludes one or more active subscriptions because conversion is unavailable
- **THEN** Insights SHALL identify the displayed total as partial and disclose the excluded subscription count

#### Scenario: No active subscription is convertible
- **WHEN** active subscriptions exist but none can be converted to the selected display currency
- **THEN** Insights SHALL describe the commitment total as unavailable and SHALL NOT display a zero converted total

### Requirement: Semantically distinct section states
Insights SHALL use different explanatory states for accumulating history, valid zero upcoming renewals, absent current subscriptions, unavailable conversion, and request failure.

#### Scenario: Fewer than two usable snapshots exist
- **WHEN** historical trend evidence has not yet accumulated two usable dated points
- **THEN** the trend section SHALL explain that history is building rather than implying an error

#### Scenario: Snapshots exist but conversion is unavailable
- **WHEN** at least two persisted snapshot periods exist but fewer than two can be converted for display
- **THEN** the trend section SHALL identify currency conversion as the reason the chart is unavailable

#### Scenario: No renewal occurs soon
- **WHEN** active subscriptions exist and none renews during the next 30 days
- **THEN** the renewal section SHALL present the result as a quiet or positive state rather than a setup failure

#### Scenario: Category totals exclude subscriptions
- **WHEN** the category visualization is based on only a subset of active subscriptions because conversion is unavailable
- **THEN** the category section SHALL disclose the number of excluded subscriptions

#### Scenario: Insight service fails
- **WHEN** optional AI insight generation fails while deterministic content is available
- **THEN** the failure SHALL remain scoped to the AI area and SHALL NOT replace deterministic sections with an empty state

### Requirement: Accessible empty and partial states
Insights activation and section states SHALL support Dynamic Type, expose meaningful VoiceOver labels, hide decorative shapes from assistive technologies, and avoid nonessential animation when Reduce Motion is enabled.

#### Scenario: VoiceOver reads the activation state
- **WHEN** assistive technology focuses the activation experience
- **THEN** it SHALL announce the explanatory content and both actions without announcing decorative chart shapes

#### Scenario: Large text is enabled
- **WHEN** the user selects a larger Dynamic Type size
- **THEN** activation content and actions SHALL reflow without truncating required instructions

#### Scenario: Reduce Motion is enabled
- **WHEN** the activation or partial state appears with Reduce Motion enabled
- **THEN** the state SHALL not use nonessential animated transitions
