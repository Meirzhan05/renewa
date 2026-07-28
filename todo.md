# Renewa Product TODO

## Navigation and visual system

- [x] Replace generic loading spinners with warm, accessible skeletons for known content, progressive Insights refresh feedback, and explicit in-button action labels.
- [x] Replace the app's interface icons with Heroicons. Add the selected SVGs as Xcode vector assets and use a consistent outlined/solid hierarchy; do not introduce a runtime web dependency.
- [x] Fix the floating **Add** tab button: it should not conflict with the tab bar's layout, selection indicator, safe area, or sheet presentation. Verify opening and dismissing the add sheet on compact and large iPhones.
- [x] Remove tab text labels, retaining clear accessibility labels and selected-state treatment for every icon.
- [x] Make the tab bar opaque and express the active tab through the icon rather than a background pill.
- [x] Redesign the tab bar as a floating, rounded control with breathing room around it.
- [x] Animate tab changes with directional page movement and a moving active-tab accent, while respecting Reduce Motion.
- [x] Remove the exchange-rate status title from the home-page spending summary.
- [x] Replace the home-page avatar with a calendar shortcut to a Logo.dev-powered upcoming-payments view.
- [x] Redesign the upcoming-payments destination as a navigable month calendar that projects active recurring subscription deadlines, supports selected-day payment details, and preserves accessible date labels.

## Subscription experience

- [x] Redesign the New Subscription flow into a more guided form with a polished category picker, billing-cycle controls, an immediate cost preview, validation, and a clear save state.
- [x] Use Logo.dev automatically for every non-empty subscription name, preferring verified catalog domains and retaining a local fallback for loading, errors, user overrides, and offline use.
- [x] Present subscription logos as contained soft-squircle brand stamps that match the app's soft card design.
- [x] Let people confirm or clear a reviewed brand logo while adding a subscription or from a subscription's context menu.
- [x] Convert subscription prices, totals, and category insights when the preferred currency changes, while preserving original amounts.
- [x] Redesign subscription removal with a calm settle-and-collapse dismissal, failure recovery, and clear completion feedback.

## Authentication and onboarding

- [x] Replace generic authentication alerts with clear inline sign-in and sign-up error states, including guidance for incorrect credentials, email confirmation, existing accounts, weak passwords, throttling, connectivity, and Google OAuth failures.
- [x] Add a required Confirm Password field and inline mismatch validation to registration. Keep the display-name field required.
- [x] Add Google account sign-in with Supabase OAuth and native PKCE. Keep Apple visual-only until an Apple Developer account and Sign in with Apple entitlement are configured.
- [x] Add a first-run onboarding flow immediately after successful registration. It should introduce the app, request the minimum useful preferences, and finish at the dashboard.
- [x] Refresh expiring Supabase JWTs before authenticated work and on foreground activation, with serialized refresh-token use and one retry after a 401.

## Profile and preferences

- [x] Simplify the profile screen by removing non-actionable account-storage and similar informational sections.
- [x] Make the profile editable: display name, avatar, preferred currency, and other relevant preferences. Persist changes to the user's Supabase profile and provide clear save/error feedback.
- [x] Add an avatar picker with a safe default placeholder and a path for future Supabase Storage upload support.
- [x] Redesign Profile as a grouped preferences hub with focused identity and currency editors, an About & licenses destination, and no AI Insights data setting.
- [x] Add the guarded in-app account-deletion flow with typed `DELETE` confirmation and a self-scoped Supabase Edge Function. Deploy and test the Function with a non-production account before release.

## Insights

- [x] Add AI-backed, explainable spending insights with cached server reports and deterministic fallback.
- [x] Add category, upcoming-renewal, and persisted monthly-spending graphs to Insights.
- [x] Replace the empty Insights dashboard with a guided activation state and distinguish history-building, quiet-renewal, unavailable-conversion, and service-failure states.
