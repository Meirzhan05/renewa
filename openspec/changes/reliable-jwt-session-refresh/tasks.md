## 1. Session refresh coordination

- [x] 1.1 Add centralized valid-token acquisition with a refresh lead window and atomic Keychain persistence.
- [x] 1.2 Serialize concurrent refresh exchanges and distinguish terminal refresh failures from transient network failures.
- [x] 1.3 Add a single authorization-failure retry helper for authenticated operations.

## 2. Authenticated integration and lifecycle

- [x] 2.1 Route subscription, profile, email, and onboarding operations through the authorized execution helper.
- [x] 2.2 Refresh eligible sessions when the SwiftUI scene becomes active without disrupting signed-out states.
- [x] 2.3 Preserve cached signed-in state during transient bootstrap failures and clear only invalid sessions.

## 3. Verification and documentation

- [x] 3.1 Update project documentation and TODOs with the JWT refresh behavior and session-recovery notes.
- [x] 3.2 Build the iOS simulator target and inspect the authorization retry/refresh call paths.
- [x] 3.3 Mark completed OpenSpec tasks and verify the change is apply-ready.
