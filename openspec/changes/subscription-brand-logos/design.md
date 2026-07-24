## Context

Renewa currently persists `icon_name` and `tint_hex` and renders a letter tile in `SubscriptionRow`. Manual entry derives that letter from the entered name; email ingestion derives it from `merchant_name`. The database has no durable brand identifier or image reference. The dashboard needs recognisable service marks without making normal list rendering dependent on an external API.

## Goals / Non-Goals

**Goals:**

- Provide consistent, real logos for a curated set of common subscription brands.
- Resolve equivalent merchant names to one stable brand identifier for both entry paths.
- Preserve the existing tile for unknown brands, offline operation, and image failures.
- Persist a compact, provider-independent brand reference and retain backward compatibility for existing rows.
- Keep the initial release free of required third-party logo-service credentials.

**Non-Goals:**

- Cataloguing every merchant, scraping arbitrary websites, or guaranteeing a logo for every subscription.
- User-uploaded logos, server-side image storage, or automatic trademark-rights verification.
- Replacing the existing category tint or letter fallback.

## Decisions

### Use a curated on-device brand catalog for the first release

A `SubscriptionBrand` catalog will map normalized aliases (for example, `netflix`, `netflix.com`) to a stable `brandID`, display name, and an asset-catalog image. Bundled assets make the UI instant, work offline, and do not expose user subscription names to a logo lookup service.

Alternative: request images from a logo API at runtime. This offers broader coverage but introduces privacy, reliability, rate-limit, and licensing dependencies. It remains a future extension behind the persisted reference.

### Store an optional stable `brand_id`, not an image blob or provider URL

Add nullable `brand_id` to `subscriptions`; use it to choose an app asset. Existing rows and unknown merchants retain `NULL`, `icon_name`, and `tint_hex`. This keeps the data portable and avoids persisting expiring URLs or duplicating images in Postgres.

Alternative: store a `logo_url`. That couples data to a provider and requires image-network and cache invalidation policy from day one.

### Resolve in every creation path and render with progressive fallback

Manual entry resolves after the name is entered and persists the matching `brand_id`. The email-scan Edge Function uses the same normalization/alias rules and writes the same identifier. The row renders, in order: bundled brand asset, letter tile. The logo view will expose the subscription name as its accessibility label and preserve the current layout dimensions.

Alternative: have the iOS client repair all email-created rows when it loads. That would cause inconsistent cross-device behavior and leave data incomplete.

### Maintain a deliberately small reviewed catalog

Initial assets and aliases will be explicitly listed and reviewed. Each logo must be sourced from an official brand asset or a license-compatible source, with attribution/license information kept in the repository where required. New entries are a data-and-asset addition, not an unbounded network lookup.

## Risks / Trade-offs

- [Trademark or asset-license misuse] → Record asset provenance, use marks only for service identification, and omit assets that cannot be used under their terms.
- [Alias false positive maps a merchant to the wrong brand] → Use exact normalized aliases, keep matching case-insensitive but conservative, and fall back for ambiguous names.
- [Catalog becomes stale] → Keep the resolver centralized, add catalog tests, and version additions through normal releases.
- [Existing records lack `brand_id`] → Make the column nullable and preserve the letter tile until a record is edited/recreated or a future migration backfills known aliases.
- [A future remote provider becomes desirable] → Keep `brand_id` independent of provider-specific URLs and add a separate resolver/cache layer only with privacy review.

## Migration Plan

1. Add a nullable `brand_id` column with no destructive migration.
2. Deploy the iOS client and Edge Function that tolerate missing values and use the fallback tile.
3. Populate `brand_id` for newly created manual and scanned subscriptions.
4. Optionally run a one-time, conservative backfill for exact known existing names after verification.
5. Roll back application code safely by ignoring the additive column; no data rollback is required.

## Open Questions

- Which initial services and official assets are approved for the launch catalog?
- Do we want an in-app selector for a user to override an incorrectly matched brand, or retain fallback-only behavior in the first release?
