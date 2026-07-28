## Context

`ProfileView` currently combines the editable name, preset avatar, currency menu, global save button, sign-out action, and Logo.dev attribution in one scrolling form. The persisted profile contains only a display name, default currency, avatar key, and onboarding state. The app also stores user-owned subscriptions, inbox connections and tokens, scan data, billing events, spend snapshots, and cached insight reports; those records use foreign keys to `auth.users` with cascading deletion.

The redesigned tab must make routine preferences discoverable without presenting account deletion as a normal setting. It must also preserve the privacy boundary from the AI Insights change: no AI control or explanation is part of the Profile data section.

## Goals / Non-Goals

**Goals:**

- Make identity and preference changes feel lightweight, clear, and accessible.
- Place irreversible deletion behind an intentional, authenticated server action and explicit textual confirmation.
- Clearly separate account/support actions from normal editing and destructive controls.
- Preserve the app's current warm visual system, Dynamic Type, VoiceOver labels, and reduced-motion behavior.

**Non-Goals:**

- Uploading profile photos or adding Supabase Storage.
- Adding an AI preference, notification settings, a paid plan, password management, or a full account-data export flow.
- Moving spending visualizations or Insight cards into Profile.
- Deleting data locally without deleting the Supabase Auth account.

## Decisions

### Grouped profile overview with focused editors

The main Profile tab will show an identity summary followed by distinct Preferences and Account/Support rows. Selecting identity opens an edit-profile sheet; selecting currency opens a focused picker. Each successful edit will persist immediately and display a concise confirmation rather than relying on a single global Save button.

This is preferred to retaining the form because each action has one clear scope and the overview remains easy to scan. The edit sheet will keep the existing preset-avatar model and use an edit/palette affordance, not a camera, because no photo upload capability exists.

### Account deletion through a self-scoped Edge Function

The client will call a new authenticated `delete-account` Edge Function only after the user has explicitly typed `DELETE` into a destructive confirmation sheet. The Function will derive the caller from the verified bearer token; it will never accept a user ID from the client. It will use the server-only Supabase service role to delete that Auth user, which cascades to the user-owned application records. On success, the client clears the saved session and returns to signed out.

This is preferred to a client/PostgREST deletion because authenticated database policies cannot delete `auth.users`, and a client-provided target user ID would create an account-takeover risk. Typed confirmation guards intent while retaining compatibility with password, Google, and Apple sign-in users; it is intentionally not presented as reauthentication.

### Account separation and disclosure

The overview will keep sign out in a normal account area, followed by a separate Danger Zone for account deletion. The deletion sheet will state that the account, subscriptions, connected-inbox credentials, email scan data, billing events, snapshots, and cached insights are permanently removed. It will include Cancel as the default action and preserve data if the request fails.

### Attribution outside Profile

Logo.dev attribution will move to a small About or Licenses destination reachable from Profile's support/account area. This satisfies the provider attribution requirement without making it look like a user profile setting.

### AI insights remain outside Profile

Profile will not introduce an AI Insights row under data settings. AI-generated explanation remains an Insights concern. If an opt-out preference is introduced in a later change, it will be designed as a dedicated AI & privacy experience with separate data-model and server behavior decisions.

## Risks / Trade-offs

- [Account deletion request succeeds server-side but the client loses connectivity before receiving it] → On the next launch, an invalid session is cleared and the user is returned to authentication; no local state is treated as proof that deletion failed.
- [A user misunderstands the permanence of deletion] → Use an isolated confirmation sheet, explicit deletion scope, typed `DELETE`, and a destructive final button.
- [Cascading foreign keys are incomplete in a deployed schema] → Verify all user-owned tables and Auth deletion behavior against a representative account before release; add explicit cleanup only for records not covered by cascades.
- [Immediate preference saves make accidental changes easier] → Use focused pickers, current-value display, and a concise saved state; name edits require valid trimmed input.
- [Logo attribution becomes hard to find] → Link it from a visible About/Licenses row and retain a direct external attribution link there.

## Migration Plan

1. Add and test the authenticated `delete-account` Function using a test account that has subscriptions, email connections, scan data, and Insight data.
2. Ship the Profile navigation and focused editors, keeping existing profile columns and update API compatible.
3. Enable the delete-account action only after the Function is deployed with its server-only service-role secret.
4. Verify successful deletion removes the Auth user and user-owned records, then verify the app clears its Keychain session.
5. Roll back by hiding the delete entry or removing Function invocation; no schema migration is required for the visual redesign.

## Open Questions

- Should a later release require recent sign-in or an email confirmation in addition to typing `DELETE`?
- Should About/Licenses be a sheet from Profile or a reusable full-screen destination shared with onboarding?
