## Why

Renewa refreshes a Supabase session only during launch, so an app left open past JWT expiry continues sending a stale access token and surfaces authorization errors. Session maintenance must become a reliable part of every authenticated workflow rather than a one-time bootstrap check.

## What Changes

- Add one centralized, concurrency-safe session-validity path that refreshes an expiring or expired JWT and atomically saves the new access and refresh token pair in Keychain.
- Refresh when the app becomes active and before authenticated requests that need a fresh token.
- Retry an authenticated request once after a 401 by refreshing the session; do not loop indefinitely.
- Treat failed or revoked refresh tokens as an authenticated sign-out: clear local session data, return to sign-in, and show an actionable message.
- Preserve ongoing signed-in state for transient network failures when a refresh cannot be attempted or completed.

## Capabilities

### New Capabilities

- `jwt-session-refresh`: Maintains a valid Supabase access token throughout the app lifecycle, serializes refresh-token use, retries authorization failures safely, and recovers predictably when a session is no longer valid.

### Modified Capabilities

- None. There is no archived baseline authentication specification in `openspec/specs/`; the current auth behavior is implemented directly in the iOS app.

## Impact

- Affected iOS components: `AppStore`, `RootView` app lifecycle handling, Keychain session persistence, and all authenticated `SupabaseClient` requests.
- No database migration, OAuth-provider configuration, or Supabase secret is required.
- Session refresh requests use the existing refresh-token endpoint and must serialize concurrent callers because refresh tokens rotate.
- Verification needs simulated expired-token, concurrent-request, refresh-success, refresh-failure, and retry-after-401 cases.
