## Context

Renewa currently persists `icon_name` and `tint_hex` and renders a letter tile in `SubscriptionRow`. Manual entry derives that letter from the entered name; email ingestion derives it from `merchant_name`. The database has no durable brand identifier or image reference. The dashboard needs recognisable service marks without making normal list rendering dependent on an external API.

## Goals / Non-Goals

**Goals:**

- Provide consistent, real logos through Logo.dev with verified domains for common subscription brands.
- Resolve equivalent merchant names to one stable brand identifier for both entry paths.
- Preserve the existing tile for offline operation and image failures.
- Persist a compact, provider-independent brand reference and retain backward compatibility for existing rows.
- Keep the core experience functional without a third-party logo-service credential and use a client-safe provider key only as an optional fallback.

**Non-Goals:**

- Cataloguing every merchant, scraping arbitrary websites, or guaranteeing a logo for every subscription.
- User-uploaded logos, server-side image storage, or automatic trademark-rights verification.
- Replacing the existing category tint or letter fallback.

## Decisions

### Use a curated domain catalog with Logo.dev's image CDN

`SubscriptionBrand` maps normalized aliases (for example, `netflix`, `netflix.com`) to stable identifiers and verified domains, not local image assets. When configured, the app uses Logo.dev's image CDN for every subscription: verified domains for the review catalog and a name endpoint for other services. Requests use `fallback=404`, so a missing or offline image returns to Renewa's own initial tile rather than a provider-generated monogram. Every outcome is framed as a circular, softly elevated brand medallion so provider image dimensions do not disrupt the app's visual language. The key is safe in client code but remains in ignored local configuration. The free commercial tier's required attribution is displayed in Profile while enabled.

Alternative: use Logo.dev's secret-key search API. Direct name images provide the same top-match behaviour without distributing a secret or adding a server-side resolver.

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
- [A remote name lookup returns the wrong brand] → Use it only after the reviewed local catalog, request provider 404 fallbacks, and retain the user-visible initial tile on failure.
- [Provider or network unavailable] → Render the initial tile immediately while the image loads, then retain it on error.

## Migration Plan

1. Add a nullable `brand_id` column with no destructive migration.
2. Deploy the iOS client and Edge Function that tolerate missing values and use the fallback tile.
3. Populate `brand_id` for newly created manual and scanned subscriptions.
4. Optionally run a one-time, conservative backfill for exact known existing names after verification.
5. Roll back application code safely by ignoring the additive column; no data rollback is required.

## Open Questions

- Which initial services and official assets are approved for the launch catalog?
- Do we want an in-app selector for a user to override an incorrectly matched brand, or retain fallback-only behavior in the first release?
