## ADDED Requirements

### Requirement: Grouped profile overview
The system SHALL present Profile as a grouped overview containing identity, app preferences, account/support actions, and a visually separate destructive-account area. The overview MUST NOT show AI Insights as a row in a data or preferences group.

#### Scenario: User opens Profile
- **WHEN** an authenticated user selects the Profile tab
- **THEN** the system displays the user's identity summary and grouped destinations for profile preferences and account actions

#### Scenario: User reviews data settings
- **WHEN** an authenticated user views the Profile overview
- **THEN** the system does not present AI Insights as part of the data or preferences settings

### Requirement: Focused identity editing
The system SHALL provide a focused edit-profile experience for changing the display name and choosing from the supported preset avatars. The identity summary MUST reflect a successfully saved change.

#### Scenario: User updates identity
- **WHEN** a user saves a valid display name or a different supported avatar
- **THEN** the system persists the changed values and updates the Profile identity summary

#### Scenario: User opens avatar editing
- **WHEN** a user opens the identity editor
- **THEN** the system presents only supported preset avatars and does not imply that a device photo can be uploaded

### Requirement: Dedicated currency preference
The system SHALL provide the default currency as a dedicated preference with its current value visible from the Profile overview. A valid selected currency MUST persist without requiring unrelated profile fields to be saved.

#### Scenario: User changes currency
- **WHEN** a user selects a supported default currency
- **THEN** the system persists that currency and confirms the saved selection

### Requirement: Account and support separation
The system SHALL place normal account/support actions apart from destructive account deletion. Third-party logo attribution MUST be reachable from an About or licenses destination and MUST NOT occupy the main Profile overview.

#### Scenario: User looks for Logo.dev attribution
- **WHEN** a user opens the Profile support or account area
- **THEN** the system provides a destination that exposes the Logo.dev attribution link

#### Scenario: User looks for destructive account actions
- **WHEN** a user views Profile
- **THEN** sign out is presented outside the separate Danger Zone and account deletion is presented only inside that Danger Zone
