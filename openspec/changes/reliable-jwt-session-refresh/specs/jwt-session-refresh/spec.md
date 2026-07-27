## ADDED Requirements

### Requirement: Valid access token for authenticated operations
The system SHALL acquire a valid Supabase access token before every authenticated REST or Edge Function operation. It MUST refresh a session whose known expiry is within the configured lead window and atomically persist the returned access and refresh token pair before using it.

#### Scenario: Token is close to expiry
- **WHEN** an authenticated operation starts and the stored access token expires within the lead window
- **THEN** the system refreshes the session, saves the replacement session in Keychain, and sends the operation with the new access token

#### Scenario: Token has no expiry metadata
- **WHEN** an authenticated operation starts with a stored session that has no expiry metadata
- **THEN** the system uses the stored token unless the server returns an authorization failure

### Requirement: Serialized session refresh
The system SHALL permit only one refresh-token exchange at a time for a session. Concurrent callers MUST await the same in-flight refresh result.

#### Scenario: Multiple requests encounter an expiring token
- **WHEN** two or more authenticated operations request a refresh concurrently
- **THEN** the system sends one refresh-token exchange and supplies its persisted result to each operation

### Requirement: Authorization failure recovery
The system SHALL refresh and retry an authenticated operation once after an HTTP 401 response. It MUST surface the subsequent error without further retries.

#### Scenario: Server rejects an otherwise valid-looking token
- **WHEN** an authenticated operation receives a 401 response
- **THEN** the system refreshes the session and retries that operation once with the new token

#### Scenario: Retried operation is unauthorized
- **WHEN** the retried operation also receives an authorization failure
- **THEN** the system stops retrying and surfaces the server error

### Requirement: Lifecycle and terminal-failure handling
The system SHALL check the session for refresh when the app becomes active. A revoked or invalid refresh response MUST clear local session data and return the app to sign-in; a transient network failure MUST retain the local session for a later retry.

#### Scenario: App returns to foreground near expiry
- **WHEN** the app becomes active and the stored token is within the refresh lead window
- **THEN** the system refreshes the session without requiring user action

#### Scenario: Refresh token is no longer valid
- **WHEN** a refresh exchange returns a terminal authorization response
- **THEN** the system clears the stored session and presents sign-in with a session-expired message

#### Scenario: Refresh request is temporarily offline
- **WHEN** a refresh exchange fails due to a transient network error
- **THEN** the system preserves the local session and allows a later foreground event or request to retry
