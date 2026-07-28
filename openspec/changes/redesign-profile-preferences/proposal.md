## Why

The Profile screen is currently a single long editing form, which makes routine account preferences feel heavier than they need to be and leaves destructive account actions undefined. Renewa needs a clearer personal hub that separates identity, preferences, account support, and irreversible deletion without mixing AI Insights into account data settings.

## What Changes

- Redesign the Profile tab as a scannable preferences hub with a compact identity header and grouped destinations instead of one persistent form.
- Move name and preset-avatar editing into a focused edit-profile experience; remove the misleading camera affordance unless photo upload is supported.
- Make currency a dedicated preference with clear, immediate confirmation rather than a global save workflow.
- Add account and support actions, including a visually separated destructive-account section.
- Add a guarded account-deletion flow that explains the data removed and requires an explicit final confirmation.
- Keep AI Insights out of the Profile data section; any future AI privacy control belongs in a dedicated AI & privacy experience rather than the default Profile overview.
- Move third-party logo attribution out of the main Profile content into an appropriate About or licenses destination.

## Capabilities

### New Capabilities

- `profile-preferences-hub`: Present and edit personal identity and app preferences through a grouped, accessible profile experience.
- `account-deletion`: Let an authenticated user permanently delete their Renewa account only through a deliberate, confirmed flow.

### Modified Capabilities

- `subscription-brand-logos`: Relocate the Logo.dev attribution from the main Profile screen to an About or licenses destination.

## Impact

- Affects `Renewa/ProfileView.swift`, profile persistence in `AppStore.swift` and `SupabaseClient.swift`, shared navigation and Heroicon assets, and profile-related models.
- Adds a server-side deletion endpoint or Edge Function and a Supabase migration/RLS-safe procedure for deleting user-owned data and the authenticated user.
- Requires user-facing copy for the destructive confirmation and verification against an account with subscriptions, email-scan history, and connected mailbox credentials.
