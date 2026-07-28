## 1. Profile preferences experience

- [x] 1.1 Refactor `ProfileView` into a grouped Profile overview with identity, Preferences, Account/Support, and a separate Danger Zone; do not add AI Insights to the overview.
- [x] 1.2 Add the focused edit-profile sheet for display name and supported preset avatars, replacing the camera-style affordance with an accurate editing affordance.
- [x] 1.3 Add a dedicated default-currency picker that saves a valid selected currency independently and shows a saved state.
- [x] 1.4 Add an About or Licenses destination reachable from Profile and move the Logo.dev attribution link into it.
- [x] 1.5 Preserve Dynamic Type, VoiceOver labels, reduced-motion behavior, and the existing Renewa visual language across the new screens and transitions.

## 2. Secure account deletion

- [x] 2.1 Implement an authenticated `delete-account` Supabase Edge Function that derives the caller from the bearer token and deletes only that caller's Auth user using a server-only service role.
- [x] 2.2 Add the client API and AppStore operation for the deletion Function, including clearing persisted session state only after successful deletion.
- [x] 2.3 Build the isolated destructive confirmation sheet with permanent-data disclosure, exact `DELETE` input validation, cancel as the default action, and safe retryable error handling.
- [ ] 2.4 Verify Auth deletion cascades to profile, subscriptions, mailbox credentials, scans, events, snapshots, and reports for a representative test account.

## 3. Verification and documentation

- [ ] 3.1 Add XCTest coverage for profile save validation and account-deletion confirmation gating when a test target is available.
- [ ] 3.2 Add Edge Function tests or local integration coverage for unauthenticated, malformed-token, and successful self-deletion requests.
- [ ] 3.3 Run the iOS simulator and unsigned device builds; manually verify focused editing, accessibility, cancellation, successful deletion, and failure recovery.
- [x] 3.4 Update `todo.md` and deployment documentation with the deletion Function configuration, required server secret, and release verification steps.
