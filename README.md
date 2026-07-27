# Renewa

Renewa is a SwiftUI subscription manager with a calm, finance-style dashboard, secure Supabase authentication and sync, and AI-assisted email discovery for new, renewed, changed, and canceled subscriptions.

All account, profile, and subscription screens use Supabase data. If the backend is not configured, the app presents a configuration screen instead of fabricated records.

## What is included

- Native SwiftUI iOS 17+ client with the supplied dashboard visual language
- Vendored Heroicons with an outlined/solid navigation hierarchy and no runtime icon dependency
- Month/year spending views, renewal reminders, category insights, manual entry, and deletion
- Coordinated springs, staggered entrances, numeric transitions, and a Reduced Motion fallback
- Supabase email/password auth with Keychain-backed sessions, proactive JWT refresh, and a one-time 401 retry
- Registration onboarding plus editable display name, avatar preset, and preferred currency
- Google account sign-in with native PKCE; Apple remains visual-only pending its entitlement
- Postgres schema, indexes, trigger-maintained profiles, grants, and row-level security
- Read-only Gmail and Microsoft Graph OAuth using the server authorization-code flow
- AES-GCM encryption for provider tokens at rest
- Authenticated Edge Function that retrieves likely billing messages and uses the OpenAI Responses API with strict Structured Outputs
- Idempotent event ingestion and automatic add/cancel updates
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

The iOS binary never receives mail-provider refresh tokens or the OpenAI key. Edge Functions hold provider credentials, refresh access server-side, pre-filter likely billing mail, truncate message content, treat email bodies as untrusted, and request strict structured output. The API request sets `store: false`. Detected events are confidence-gated at `0.72`, deduplicated, and auditable in `detected_billing_events`.

`store: false` disables Responses API application-state storage, but default API abuse-monitoring retention may still apply. Organizations handling sensitive mail should review OpenAI data controls and eligibility for Zero Data Retention before production.

Before shipping, add a privacy policy, account/data deletion, provider disconnection and token revocation UI, App Store privacy disclosures, rate limiting, monitoring, and representative extraction evals. Mail access is sensitive; keep the requested scopes read-only and minimal.

## Project map

```text
Renewa/                         SwiftUI client
  AppStore.swift                Session and subscription state
  SupabaseClient.swift          Auth, PostgREST, and Function requests
  OnboardingView.swift          First-run profile and preference setup
  HeroIcon.swift                Vendored Heroicons asset adapter
  OverviewView.swift            Reference-inspired dashboard
  EmailScanView.swift           OAuth and AI scan UX
supabase/
  migrations/                   Database, grants, RLS, and triggers
  functions/mail-oauth-*        Gmail/Microsoft authorization flow
  functions/email-scan          Mail retrieval, AI extraction, and reconciliation
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
```
