## ADDED Requirements

### Requirement: Contained subscription brand stamp
The system SHALL render every subscription visual inside a Renewa-aligned soft-squircle frame. Provider artwork MUST preserve its aspect ratio, MUST NOT be cropped, and MUST use a transparent-capable format. The initial/category fallback MUST use the same outer frame.

#### Scenario: Verified logo is available
- **WHEN** a subscription has a reviewed brand identifier and the provider image loads
- **THEN** the app displays the logo centered within the soft-squircle frame without cropping it

#### Scenario: Provider image is unavailable
- **WHEN** a reviewed provider image is loading, fails, or the device is offline
- **THEN** the app displays the subscription's existing initial/category fallback in the same frame

### Requirement: Verified automatic logo association
The system SHALL request a remote logo only when a subscription has a reviewed `brand_id` that maps to a verified domain. The system MUST NOT automatically use name-based provider lookup for unknown subscription names.

#### Scenario: Known manual subscription
- **WHEN** a user enters a name that exactly matches a reviewed catalog alias
- **THEN** the app persists the corresponding brand identifier and displays its verified-domain logo when available

#### Scenario: Unknown subscription
- **WHEN** a subscription has no reviewed brand identifier
- **THEN** the app displays its fallback visual and does not request a name-based provider logo

### Requirement: Confirmed brand selection
The system SHALL let users choose a reviewed brand or clear the brand choice while adding a subscription and from an existing subscription's logo action. A confirmed choice MUST be persisted in the existing `brand_id` field under the authenticated user's ownership.

#### Scenario: User confirms a reviewed brand
- **WHEN** a user selects a reviewed brand and saves the selection
- **THEN** the app persists that brand identifier and updates the displayed subscription logo

#### Scenario: User clears the brand choice
- **WHEN** a user chooses the fallback option
- **THEN** the app persists no brand identifier and displays the initial/category fallback

### Requirement: Presentation cache refresh
The system SHALL include a presentation-version cache boundary in remote logo URLs so an updated logo treatment does not reuse prior cached image responses.

#### Scenario: Brand presentation is updated
- **WHEN** the application requests a logo after a presentation version change
- **THEN** the request uses a distinct cache identity from the previous presentation version
