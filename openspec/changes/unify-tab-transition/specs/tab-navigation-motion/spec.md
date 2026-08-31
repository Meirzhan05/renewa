## ADDED Requirements

### Requirement: Uniform primary-tab transition
The application SHALL use the same screen transition for every change between Home, Insights, Inbox, and Profile, independent of transition direction.

#### Scenario: Switching from Home
- **WHEN** the user selects any other primary tab while Home is active
- **THEN** the new tab and Home use the same uniform transition used by any other primary-tab switch

#### Scenario: Returning to Home
- **WHEN** the user selects Home while another primary tab is active
- **THEN** Home uses the same uniform transition used by any other primary-tab switch

### Requirement: Reduced-motion tab transition
The application SHALL use an opacity-only primary-tab transition when the user enables Reduce Motion.

#### Scenario: Reduce Motion enabled
- **WHEN** the user changes primary tabs while Reduce Motion is enabled
- **THEN** the screen transition changes opacity without translation or scale movement
