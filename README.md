# Renewa

Renewa is a SwiftUI subscription manager with a calm, finance-style dashboard, secure Supabase authentication and sync, and AI-assisted email discovery for new, renewed, changed, and canceled subscriptions.

All account, profile, and subscription screens use Supabase data. If the backend is not configured, the app presents a configuration screen instead of fabricated records.

## What is included

- Native SwiftUI iOS 17+ client with the supplied dashboard visual language
- Vendored Heroicons with an outlined/solid navigation hierarchy and no runtime icon dependency
- Month/year spending views, a Logo.dev-powered upcoming-payments calendar, renewal reminders, category insights, manual entry, and deletion
- A guided first-time Insights state with direct manual-entry and inbox-discovery actions, honest partial-data and currency-conversion messaging, and transparent AI-versus-fallback summary provenance
- Coordinated springs, staggered entrances, numeric transitions, and a Reduced Motion fallback
- Supabase email/password auth with Keychain-backed sessions, proactive JWT refresh, and a one-time 401 retry
- Registration onboarding plus editable display name, avatar preset, and preferred currency
- Google account sign-in with native PKCE; Apple remains visual-only pending its entitlement
- Postgres schema, indexes, trigger-maintained profiles, grants, and row-level security
- Read-only Gmail and Microsoft Graph OAuth using the server authorization-code flow
- AES-GCM encryption for provider tokens at rest
- Authenticated, resumable inbox-discovery jobs with Gmail history and Microsoft delta synchronization
- Metadata-first billing selection and per-message DeepSeek-compatible structured extraction with runtime validation
- Idempotent event ingestion plus editable, review-first add/update/cancel proposals
- Canceled-subscription history and live-currency converted spending totals
- Logo.dev brand logos with an accessible initial-and-category fallback for every other subscription

## Run the iOS app

1. Start Docker.
2. Run `npx --yes supabase@2.109.1 start`.
3. Create the ignored `Config.local.xcconfig` shown below.
4. Open `Renewa.xcodeproj`, choose an iPhone simulator, and run.

Create `Config.local.xcconfig` with the public values printed by `npx --yes supabase@2.109.1 status -o env`:

```xcconfig
SUPABASE_URL = http:/$()/127.0.0.1:54321
SUPABASE_PUBLISHABLE_KEY = YOUR_PUBLISHABLE_KEY
LOGO_DEV_PUBLISHABLE_KEY = pk_YOUR_LOGO_DEV_PUBLISHABLE_KEY
```

The publishable key is intended for client apps. Never put a Supabase secret/service-role key, DeepSeek key, Google client secret, Microsoft client secret, or mail encryption key in the iOS project.

### Enable Google account sign-in

In Supabase Dashboard, open **Authentication → Providers → Google**, enable it, and enter the Google OAuth client ID and client secret. In Google Cloud, add the Supabase callback URI shown in that Provider screen (for this project: `https://fxwbhblcbrmbzrozlbwv.supabase.co/auth/v1/callback`). Finally, add `renewa://auth` to **Authentication → URL Configuration → Redirect URLs**. This account sign-in setup is separate from the Gmail inbox callback below.

To exercise Functions locally, copy `supabase/functions/.env.example` to the ignored `supabase/functions/.env`, fill the external provider values, then run:

```sh
npx --yes supabase@2.109.1 functions serve \
  --env-file supabase/functions/.env
```

## Deploy the backend

Install the [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started), then:

```sh
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
cp supabase/functions/.env.example supabase/functions/.env
```

Fill the local `.env`, then upload its values and deploy:

```sh
supabase secrets set --env-file supabase/functions/.env
supabase functions deploy mail-oauth-start
supabase functions deploy mail-oauth-callback --no-verify-jwt
supabase functions deploy email-scan
```

Supabase provides the project URL and client/server keys to hosted Edge Functions. The functions accept both the newer `SUPABASE_PUBLISHABLE_KEY` / `SUPABASE_SECRET_KEY` names and the legacy `SUPABASE_ANON_KEY` / `SUPABASE_SERVICE_ROLE_KEY` names. The other required secrets are documented in `.env.example`.

## Configure mail providers

Use this callback URL in both provider consoles:

```text
https://YOUR_PROJECT.supabase.co/functions/v1/mail-oauth-callback
```

For Google:

- Enable the Gmail API.
- Create a web OAuth client.
- Request `openid`, `email`, and `gmail.readonly`.
- Production access to Gmail scopes may require Google OAuth verification.

For Microsoft:

- Create a Microsoft Entra app registration.
- Add delegated `User.Read` and `Mail.Read` permissions.
- Request `offline_access` for refresh tokens.
- Add the callback URL as a web redirect URI.

## AI and privacy design

The iOS binary never receives mail-provider refresh tokens or the DeepSeek key. The authenticated `email-scan` Function creates durable user-owned jobs and returns immediately; background work is resumable through persisted job state. Gmail scans advance from a mailbox history ID and Microsoft scans advance from an opaque Inbox delta link only after successful processing.

Renewa evaluates bounded message metadata and snippets first, retrieves full content only for likely billing messages, sanitizes and truncates that content, and processes one message per constrained extraction request. Raw bodies and raw model payloads are never persisted by Renewa. The model has no tools and cannot change subscriptions. Runtime validation, source-message fingerprints, and a deterministic per-merchant lifecycle reducer distinguish current, explicitly ended, and uncertain evidence before candidates are created. Old receipts without current renewal evidence do not enter the review queue; an explicit later cancellation supersedes earlier receipts. Additions, updates, reactivations, and cancellations still require explicit user confirmation.

The configured model endpoint is DeepSeek-compatible Chat Completions in JSON response mode. Renewa's non-retention of raw content does not control the AI provider's own processing or abuse-monitoring practices. Review the provider's current data terms, regional requirements, and production privacy agreement before deployment.

Insights sends only the user’s stored subscription facts, validated billing-event facts, scan outcome, and aggregate spending snapshots to its server-side model request. The result identifies whether it is AI-generated or a deterministic fallback, whether it was served from the 24-hour cache, when it was generated, and only non-zero aggregate evidence counts. Provider error text, prompts, raw email content, and secrets are never shown in the iOS app. See [INSIGHTS_SETUP.md](supabase/INSIGHTS_SETUP.md) for deployment and retry behavior.

Users can mark a suggested merchant as “I don’t use this” to suppress future discovery proposals without canceling or changing a confirmed subscription; suppression is reversible through the authenticated API. Incremental evidence is best-effort and Inbox-focused after the bounded initial scan, so absence of a message never proves that a service is active or ended. Users can also inspect redacted connection state, disconnect an inbox, trigger best-effort Google token revocation, and clear discovery history without removing confirmed subscriptions. Microsoft does not expose an equivalent delegated refresh-token revocation endpoint to this app, so disconnect deletes Renewa's encrypted credential and prevents further access. Before public release, complete the privacy policy, App Store privacy disclosure, provider verification, representative multilingual extraction evaluation, and production rate/latency monitoring. See [EMAIL_DISCOVERY_SETUP.md](supabase/EMAIL_DISCOVERY_SETUP.md).

Inbox Intelligence stores only validated billing facts, compact evidence summaries, user-reviewed merchant aliases, and aggregate quality outcomes. Raw email bodies and raw model payloads remain transient. A second advisory model pass is reserved for configured merchant-identity ambiguity and never receives tools, subscription IDs, or mutation authority; its result cannot bypass review.

During onboarding, people can explicitly connect Google or Microsoft to run a bounded historical discovery scan. Connected inboxes then use daily incremental monitoring through their existing provider cursor; see [EMAIL_DISCOVERY_SETUP.md](supabase/EMAIL_DISCOVERY_SETUP.md) for the required server-only scheduler setup and opt-out/disconnect behavior.

## Project map

```text
Renewa/                         SwiftUI client
  AppStore.swift                Session and subscription state
  SupabaseClient.swift          Auth, PostgREST, and Function requests
  OnboardingView.swift          First-run profile and preference setup
  HeroIcon.swift                Vendored Heroicons asset adapter
  OverviewView.swift            Reference-inspired dashboard
  PaymentCalendarView.swift     Upcoming payments grouped by renewal month
  InsightsView.swift            Insight activation, summaries, and visualizations
  InsightsPresentationState.swift
                                Testable Insights evidence and completeness states
  InsightsSummaryPresentationState.swift
                                Testable AI provenance and fallback presentation rules
  EmailScanView.swift           OAuth, scan progress, connection controls, and review UX
  EmailDiscoveryPresentationState.swift
                                Testable scan and candidate presentation rules
RenewaTests/                    XCTest coverage for client presentation logic
supabase/
  migrations/                   Database, grants, RLS, and triggers
  functions/mail-oauth-*        Gmail/Microsoft authorization flow
  functions/email-scan          Durable coordination, incremental mail retrieval, extraction, and review
  functions/_shared/email-discovery.ts
                                Pure filtering, minimization, validation, and matching rules
```

## Subscription brand logos

Renewa stores an optional, provider-independent `brand_id` to provide verified Logo.dev domains for reviewed services. Every other non-empty subscription name receives an automatic Logo.dev name lookup, while users can replace it with a reviewed brand or choose the local initial fallback. Every logo is shown in a contained soft-squircle stamp, with the same fallback during loading, errors, and offline use. See [SubscriptionBrandLogos.md](Renewa/ThirdPartyLicenses/SubscriptionBrandLogos.md) for attribution and trademark notes.

To use Logo.dev for automatic subscription logos, create its free account and add the client-safe `pk_…` key as `LOGO_DEV_PUBLISHABLE_KEY` in `Config.local.xcconfig`. Renewa requests transparent PNG logos from a verified domain when available and otherwise from Logo.dev's name endpoint; a name match is automatic, not a verified identity. Users can choose a reviewed brand or keep the local initial from the add flow or a subscription's context menu. The free commercial tier requires the in-app Logo.dev attribution that appears in Profile.

## Session refresh

Renewa keeps the Supabase access token and its rotating refresh token together in the iOS Keychain. Before each authenticated request—and when the app becomes active—it refreshes a token nearing expiry. A 401 response gets one refresh-and-retry attempt. Invalid refresh tokens return the person to sign-in; temporary network failures retain the saved session so it can recover later.

## Currency conversion

Each subscription retains the amount and ISO currency in which it was created or discovered. When a user changes **Preferred currency** in Profile, Renewa refreshes current reference rates from the no-key [Frankfurter API](https://frankfurter.dev/) and converts dashboard totals, category insights, and subscription-row display values. The original amount remains visible beneath a converted row value and is never rewritten. If rates cannot be retrieved, Renewa explicitly keeps that original amount visible rather than presenting a misleading conversion.

## Verification

The project builds without third-party iOS dependencies:

```sh
xcodebuild -project Renewa.xcodeproj -target Renewa \
  -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Renewa.xcodeproj -target Renewa \
  -configuration Debug -sdk iphonesimulator -arch arm64 \
  SYMROOT=/tmp/RenewaBuild OBJROOT=/tmp/RenewaObj build
xcodebuild -project Renewa.xcodeproj -scheme Renewa \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
xcrun swift-format lint --configuration .swift-format \
  Renewa/InsightsView.swift Renewa/InsightsPresentationState.swift \
  Renewa/InsightsSummaryPresentationState.swift Renewa/RootView.swift \
  RenewaTests/InsightsPresentationStateTests.swift \
  RenewaTests/InsightsSummaryPresentationStateTests.swift
```
