## 1. Session refresh coordination

- [ ] 1.1 Add centralized valid-token acquisition with a refresh lead window and atomic Keychain persistence.
- [ ] 1.2 Serialize concurrent refresh exchanges and distinguish terminal refresh failures from transient network failures.
- [ ] 1.3 Add a single authorization-failure retry helper for authenticated operations.

## 2. Authenticated integration and lifecycle

- [ ] 2.1 Route subscription, profile, email, and onboarding operations through the authorized execution helper.
- [ ] 2.2 Refresh eligible sessions when the SwiftUI scene becomes active without disrupting signed-out states.
- [ ] 2.3 Preserve cached signed-in state during transient bootstrap failures and clear only invalid sessions.

## 3. Verification and documentation

- [ ] 3.1 Update project documentation and TODOs with the JWT refresh behavior and session-recovery notes.
- [ ] 3.2 Build the iOS simulator target and inspect the authorization retry/refresh call paths.
- [ ] 3.3 Mark completed OpenSpec tasks and verify the change is apply-ready.
