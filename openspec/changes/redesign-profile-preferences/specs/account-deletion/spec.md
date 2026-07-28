## ADDED Requirements

### Requirement: Guarded account-deletion confirmation
The system SHALL require an authenticated user to open a dedicated account-deletion confirmation experience and enter the exact confirmation text `DELETE` before enabling the final deletion action. The confirmation experience MUST state that deletion is permanent and identify the categories of data removed.

#### Scenario: User starts account deletion
- **WHEN** a user selects Delete account from the Danger Zone
- **THEN** the system presents a dedicated confirmation experience with the deletion consequences and a disabled final action until `DELETE` is entered exactly

#### Scenario: User cancels deletion
- **WHEN** a user dismisses or cancels the deletion confirmation experience
- **THEN** the system retains the account and all user data

### Requirement: Self-scoped permanent deletion
The system SHALL use an authenticated server-side operation that derives the account to delete from the caller's verified session. The operation MUST permanently delete the authenticated user's Auth identity and its user-owned Renewa records, and it MUST NOT accept a client-supplied target user identifier.

#### Scenario: Confirmed deletion succeeds
- **WHEN** an authenticated user enters `DELETE` and confirms deletion
- **THEN** the system deletes that user's Auth identity and associated Renewa records, clears the local session, and returns the user to the signed-out state

#### Scenario: Deletion fails
- **WHEN** the server-side deletion operation returns an error
- **THEN** the system keeps the local session and account data intact, reports that deletion was not completed, and allows the user to cancel or retry

### Requirement: Deletion disclosure
The system SHALL disclose that account deletion permanently removes profile data, subscriptions, connected-inbox credentials, email scan history, billing events, spending snapshots, and cached Insight reports.

#### Scenario: User reviews deletion scope
- **WHEN** a user opens the deletion confirmation experience
- **THEN** the system describes the categories of permanently removed data before the final deletion action
