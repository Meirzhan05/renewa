## Context

Renewa uses a custom `SupabaseClient` and stores its session in Keychain. It currently refreshes only while bootstrapping a cached session that expires within 60 seconds. Requests made after launch use the stored access token directly, and the app has neither a foreground lifecycle refresh nor an authorization-failure retry. Because Supabase refresh tokens rotate, concurrent refreshes must also be serialized.

## Goals / Non-Goals

**Goals:**

- Supply a valid access token for every authenticated operation while avoiding unnecessary refreshes.
- Persist a newly issued access and refresh token as one session record before any caller uses it.
- Refresh on foreground activation and retry exactly once after a 401.
- Keep users signed in across transient refresh/network failures, but safely clear a revoked or invalid session.

**Non-Goals:**

- Migrating to the Supabase Swift SDK, changing JWT lifetimes, or altering server-side Auth settings.
- Retrying non-authorization errors, indefinitely retrying requests, or refreshing while the app is backgrounded.
- Synchronizing sessions between devices beyond Supabase's existing session rules.

## Decisions

### Centralize token acquisition in AppStore

All authenticated store operations call one `authorized` execution helper. It obtains a token through `validAccessToken`, refreshes when expiry is inside a small lead window, and retries the operation once only if its first attempt returns a 401. This protects every REST and Edge Function operation without duplicating refresh logic.

Alternative: refresh only in each view. This leaves background operations and future call sites inconsistent.

### Serialize refresh with one shared task

`AppStore` retains an in-flight refresh task. Callers arriving while a refresh is underway await the same task rather than sending the same rotating refresh token twice. The task updates memory and Keychain before being released.

Alternative: lock every request or trust refresh-token reuse behavior. A lock unnecessarily serializes normal API work, while concurrent refresh calls remain fragile.

### Use lifecycle and request-driven refresh together

When SwiftUI reports an active scene, the store proactively refreshes only if the token is nearing expiry. Every authenticated request independently performs the same check, and a 401 forces a single refresh-and-retry to account for revoked tokens, clock changes, and server validation.

Alternative: use a perpetual timer. iOS can suspend the app, so timers alone cannot guarantee a valid token at the next request.

### Differentiate terminal refresh failures from transient failures

Invalid-grant-style refresh failures (HTTP 400/401/403 from refresh) clear Keychain and return to sign-in with a session-expired message. Transport failures leave the saved session and UI state intact, allowing a later foreground event or request to recover.

Alternative: clear the session for any failure. This logs users out merely because they were briefly offline.

## Risks / Trade-offs

- [A 401 is caused by RLS rather than expiration] → Retry only once; preserve the server error if the retry fails.
- [Refresh task is cancelled] → Clear the in-flight task reference and keep the persisted session unchanged until a successful refresh.
- [No `expires_at` value is supplied] → Use the existing token until a 401 prompts one forced refresh, rather than guessing an expiry.
- [Token refresh succeeds but Keychain write fails] → Treat the operation as failed and retain a clear error rather than continuing with an unpersisted rotated token.

## Migration Plan

1. Ship the iOS-only refresh coordinator and lifecycle hook; no backend migration is required.
2. Existing Keychain sessions remain decodable and are refreshed on demand.
3. Monitor authorization errors; a terminal refresh failure requires normal sign-in, while offline failures remain recoverable.
4. Roll back by removing the coordinator; persisted session structure remains compatible.

## Open Questions

- A future XCTest target should cover expiry calculations, simultaneous refresh callers, a single 401 retry, and terminal versus transient refresh failures.
