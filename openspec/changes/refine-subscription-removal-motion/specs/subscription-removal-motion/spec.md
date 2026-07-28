## ADDED Requirements

### Requirement: Calm subscription removal motion
The home subscription list SHALL acknowledge a successful removal request with a brief low-amplitude settle followed by a vertical collapse, and the remaining rows SHALL reflow as the removed row leaves the list. The normal-motion path MUST NOT use blur, 3D perspective rotation, or a substantial horizontal throw.

#### Scenario: Removing an active subscription
- **WHEN** a person chooses Remove for an active subscription from the home-page context menu
- **THEN** the selected row briefly settles, collapses vertically, and the remaining active rows move into place with a restrained animation

#### Scenario: Removing an inactive subscription
- **WHEN** a person chooses Delete permanently for an inactive subscription from the home-page context menu
- **THEN** the selected row uses the same calm removal motion and the inactive list reflows smoothly

### Requirement: Accessible removal outcome
The home subscription list SHALL honor the system Reduce Motion preference during removal and recovery, while retaining non-visual confirmation of the completed deletion.

#### Scenario: Reduced Motion removal
- **WHEN** Reduce Motion is enabled and a subscription is removed
- **THEN** the row uses a short opacity-only transition without scale, collapse, rotation, blur, or horizontal movement

#### Scenario: Completed removal feedback
- **WHEN** the deletion request succeeds
- **THEN** the app provides the existing success haptic and accessible textual confirmation identifying the removed subscription

### Requirement: Failed deletion recovery
The home subscription list SHALL restore a row when its deletion request fails.

#### Scenario: Deletion request fails
- **WHEN** the backend deletion request for a subscription fails after its removal motion begins
- **THEN** the original row returns to its list position with a restrained recovery transition and remains available to the person
