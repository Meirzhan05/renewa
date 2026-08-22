# Renewa Product TODO

## Navigation and visual system

- [x] Replace generic loading spinners with warm, accessible skeletons for known content, progressive Insights refresh feedback, and explicit in-button action labels.
- [x] Replace the app's interface icons with Heroicons. Add the selected SVGs as Xcode vector assets and use a consistent outlined/solid hierarchy; do not introduce a runtime web dependency.
- [x] Fix the floating **Add** tab button: it should not conflict with the tab bar's layout, selection indicator, safe area, or sheet presentation. Verify opening and dismissing the add sheet on compact and large iPhones.
- [x] Remove tab text labels, retaining clear accessibility labels and selected-state treatment for every icon.
- [x] Make the tab bar opaque and express the active tab through the icon rather than a background pill.
- [x] Redesign the tab bar as a floating, rounded control with breathing room around it.
- [x] Animate tab changes with directional page movement and a moving active-tab accent, while respecting Reduce Motion.
- [x] Give all interactive buttons a visible press acknowledgment through the shared scale, opacity, and brightness feedback style; retain an opacity-only response for Reduce Motion.
- [x] Remove the exchange-rate status title from the home-page spending summary.
- [x] Replace the home-page avatar with a calendar shortcut to a Logo.dev-powered upcoming-payments view.
- [x] Redesign the upcoming-payments destination as a navigable month calendar that projects active recurring subscription deadlines, supports selected-day payment details, preserves accessible date labels, and animates month/date changes while honoring Reduce Motion.

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
- [x] Add a first-run onboarding flow immediately after successful registration. It should introduce the app, request the minimum useful preferences, require an explicit inbox-scan or not-now choice, and finish at the dashboard.
- [x] Refresh expiring Supabase JWTs before authenticated work and on foreground activation, with serialized refresh-token use and one retry after a 401.

## Profile and preferences

- [x] Simplify the profile screen by removing non-actionable account-storage and similar informational sections.
- [x] Make the profile editable: display name, avatar, preferred currency, and other relevant preferences. Persist changes to the user's Supabase profile and provide clear save/error feedback.
- [x] Add an avatar picker with a safe default placeholder and a path for future Supabase Storage upload support.
- [x] Redesign Profile as a grouped preferences hub with focused identity and currency editors, an About & licenses destination, and no AI Insights data setting.
- [x] Add the guarded in-app account-deletion flow with typed `DELETE` confirmation and a self-scoped Supabase Edge Function. Deploy and test the Function with a non-production account before release.
- [x] Confirm sign-out intent before ending the current session, with a clear cancel option and explanation of the effect.

## Insights

- [x] Add AI-backed, explainable spending insights with cached server reports and deterministic fallback.
- [x] Add category, upcoming-renewal, and persisted monthly-spending graphs to Insights.
- [x] Replace the empty Insights dashboard with a guided activation state and distinguish history-building, quiet-renewal, unavailable-conversion, and service-failure states without indefinite skeleton loading.

## Inbox discovery

- [x] Replace synchronous bulk email extraction with resumable per-inbox jobs, Gmail history cursors, Microsoft delta links, metadata-first filtering, and per-message runtime-validated AI extraction that safely skips malformed model replies.
- [x] Keep AI proposals review-first: let people correct, confirm, or ignore detected additions and changes before subscriptions are mutated.
- [x] Show redacted connection health and scan progress, and support disconnect, best-effort token revocation, and scan-history cleanup.
- [x] Treat expected cancellation from tab navigation or dismissed OAuth sheets as non-errors, so background scan work never raises a false global alert.
- [x] Add backend extraction fixtures and iOS presentation tests for candidate validation, prompt-injection boundaries, idempotency, progress, and confirmation eligibility.
- [x] Harden OAuth token-expiry validation and deploy the inbox-discovery migration plus mail OAuth and scan Functions to the linked Supabase project.
- [x] Add evidence-backed inbox discovery foundations: merchant bundles, reviewed aliases, bounded advisory identity validation, and privacy-minimized review outcomes. Validate against redacted fixtures before considering additional automation.
- [x] Add opt-in full-mailbox onboarding discovery with resumable pages, explicit connection/scan feedback, and daily cursor-based monitoring; configure the protected Supabase scheduler before enabling it in production.
- [x] Reconcile per-merchant email evidence into current, ended, or uncertain lifecycle outcomes so obsolete receipts never become actionable subscriptions; allow reversible unused-merchant suppression.
- [x] Add opt-in Inbox Intelligence outcome alerts with durable, privacy-minimized delivery records, a manual-scan Live Activity, deep linking, APNs invalid-token cleanup, and deployment/runbook documentation; physical APNs delivery remains a release verification step.
- [x] Redesign Inbox Intelligence as a quiet assistant-first surface: pending reviews stay primary, monitoring status stays compact, and settings, diagnostics, and lifecycle history are progressively disclosed.
- [x] Add a compact Latest check proof-of-work card so Inbox Intelligence explains recent inbox activity without restoring a dashboard or exposing email content.
- [x] Prioritize recent subscription evidence by limiting first-time historical inbox discovery to 180 days and provider-cursor recovery to 90 days.
- [ ] Add verified Gmail Pub/Sub and Microsoft Graph event monitoring with debounced cursor scans, watch renewal, daily reconciliation, and truthful Inbox Intelligence monitoring health. Code and local verification are complete; hosted provider setup and staged rollout remain.
