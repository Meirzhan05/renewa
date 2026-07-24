# Renewa Product TODO

## Navigation and visual system

- [x] Replace the app's interface icons with Heroicons. Add the selected SVGs as Xcode vector assets and use a consistent outlined/solid hierarchy; do not introduce a runtime web dependency.
- [x] Fix the floating **Add** tab button: it should not conflict with the tab bar's layout, selection indicator, safe area, or sheet presentation. Verify opening and dismissing the add sheet on compact and large iPhones.
- [x] Remove tab text labels, retaining clear accessibility labels and selected-state treatment for every icon.

## Subscription experience

- [x] Redesign the New Subscription flow into a more guided form with a polished category picker, billing-cycle controls, an immediate cost preview, validation, and a clear save state.

## Authentication and onboarding

- [x] Add a required Confirm Password field and inline mismatch validation to registration. Keep the display-name field required.
- [x] Add visual Apple and Google sign-in buttons to the authentication screen. Wire Google only after its OAuth credentials are available; treat Apple as visual-only until an Apple Developer account and Sign in with Apple entitlement are configured.
- [x] Add a first-run onboarding flow immediately after successful registration. It should introduce the app, request the minimum useful preferences, and finish at the dashboard.

## Profile and preferences

- [x] Simplify the profile screen by removing non-actionable account-storage and similar informational sections.
- [x] Make the profile editable: display name, avatar, preferred currency, and other relevant preferences. Persist changes to the user's Supabase profile and provide clear save/error feedback.
- [x] Add an avatar picker with a safe default placeholder and a path for future Supabase Storage upload support.
