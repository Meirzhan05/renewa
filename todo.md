# Renewa Product TODO

## Navigation and visual system

- [x] Replace the app's interface icons with Heroicons. Add the selected SVGs as Xcode vector assets and use a consistent outlined/solid hierarchy; do not introduce a runtime web dependency.
- [x] Fix the floating **Add** tab button: it should not conflict with the tab bar's layout, selection indicator, safe area, or sheet presentation. Verify opening and dismissing the add sheet on compact and large iPhones.
- [x] Remove tab text labels, retaining clear accessibility labels and selected-state treatment for every icon.

## Subscription experience

- [x] Redesign the New Subscription flow into a more guided form with a polished category picker, billing-cycle controls, an immediate cost preview, validation, and a clear save state.
- [x] Use Logo.dev for reviewed subscription logos, retaining a local fallback for loading, errors, unknown services, and offline use.
- [x] Present subscription logos as contained soft-squircle brand stamps that match the app's soft card design.
- [x] Let people confirm or clear a reviewed brand logo while adding a subscription or from a subscription's context menu.
- [x] Convert subscription prices, totals, and category insights when the preferred currency changes, while preserving original amounts.
- [x] Redesign subscription removal with an immediate card-dismiss animation, failure recovery, and completion feedback.

## Authentication and onboarding

- [x] Add a required Confirm Password field and inline mismatch validation to registration. Keep the display-name field required.
- [x] Add Google account sign-in with Supabase OAuth and native PKCE. Keep Apple visual-only until an Apple Developer account and Sign in with Apple entitlement are configured.
- [x] Add a first-run onboarding flow immediately after successful registration. It should introduce the app, request the minimum useful preferences, and finish at the dashboard.

## Profile and preferences

- [x] Simplify the profile screen by removing non-actionable account-storage and similar informational sections.
- [x] Make the profile editable: display name, avatar, preferred currency, and other relevant preferences. Persist changes to the user's Supabase profile and provide clear save/error feedback.
- [x] Add an avatar picker with a safe default placeholder and a path for future Supabase Storage upload support.
