## Why

The current verified-brand-only policy avoids incorrect matches, but makes logos feel manual and incomplete when someone creates a subscription outside the small reviewed catalog. Renewa should assign a real logo automatically from every meaningful subscription name while retaining a safe way to recover from a mistaken match.

## What Changes

- Restore Logo.dev's automatic name-based image lookup for manual subscriptions that do not already have a verified catalog brand.
- Preserve verified-domain requests as the preferred route whenever a catalogued `brand_id` exists.
- Keep the soft-squircle stamp, transparent image treatment, loading/error fallback, and user-visible logo override controls.
- Record automatic lookup as a presentation-time fallback rather than storing a provider URL or treating a guessed company as a verified catalog match.
- Define a follow-on server-side merchant-enrichment path for email-derived subscription descriptors, using a protected Logo.dev secret key to resolve canonical domains and confidence before persistence.

## Capabilities

### New Capabilities

- `automatic-subscription-logo-lookup`: Automatically displays a Logo.dev name-match logo for subscriptions outside the reviewed brand catalog, while preserving verified-domain precedence, fallback behavior, and a reversible user override.
- `merchant-logo-enrichment`: Defines the future protected backend path for resolving email-derived merchant descriptors to canonical domains and logos with confidence-aware handling.

### Modified Capabilities

- None. `subscription-logo-presentation` exists only as a completed, unarchived change rather than an archived baseline capability.

## Impact

- Affected iOS UI and networking: `SubscriptionBrandIcon`, Logo.dev URL construction, the add-subscription preview, and the existing brand picker.
- Existing `brand_id` stays provider-independent and continues to identify verified catalog brands; no migration is needed for the immediate name lookup.
- The future enrichment phase affects the `email-scan` Edge Function and introduces a server-only Logo.dev secret. It must never expose that credential to the iOS app.
- Automatic name matches can be incorrect for ambiguous names, so the UI must retain a clear replacement/clear action and should not claim an unverified result is confirmed.
