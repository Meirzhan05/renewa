## 1. Brand catalog and assets

- [ ] 1.1 Define a centralized Swift `SubscriptionBrand` catalog with stable identifiers, conservative normalized aliases, display names, and asset names.
- [ ] 1.2 Select the initial supported services and add their reviewed bundled image assets to `Renewa/Assets.xcassets`.
- [ ] 1.3 Record the provenance or license information for every bundled third-party logo and add catalog-resolution tests.

## 2. Persistence and ingestion

- [ ] 2.1 Add a forward-only Supabase migration that introduces nullable `brand_id` on `public.subscriptions`.
- [ ] 2.2 Extend the Swift `Subscription` model and PostgREST insert payload to decode and encode the optional brand identifier while remaining compatible with existing records.
- [ ] 2.3 Resolve the brand identifier during manual subscription creation.
- [ ] 2.4 Add matching normalization/catalog logic to the email-scan Edge Function and persist `brand_id` for created or updated subscriptions.

## 3. Subscription experience

- [ ] 3.1 Replace the shared subscription-row icon tile with a reusable brand-logo view that renders the bundled asset when available.
- [ ] 3.2 Preserve the existing tinted initial tile for unknown brands, legacy records, and unavailable assets without changing row dimensions or animation behavior.
- [ ] 3.3 Add an accessibility label based on the subscription name and verify the visual in active and canceled subscription lists.

## 4. Verification and release readiness

- [ ] 4.1 Add XCTest coverage for normalized alias matching, known/unknown fallback behavior, and `brand_id` API decoding.
- [ ] 4.2 Add Edge Function tests or testable coverage for matching known and unknown email merchant names.
- [ ] 4.3 Apply the migration to a local Supabase instance and verify manual creation plus email-ingestion persistence.
- [ ] 4.4 Build the iOS simulator target, inspect the logo and fallback states, and confirm VoiceOver labels.
- [ ] 4.5 Update `todo.md` and project documentation with the supported catalog, licensing records, and migration/deployment notes.
