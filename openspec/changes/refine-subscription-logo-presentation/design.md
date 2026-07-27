## Context

Renewa currently records an optional provider-independent `brand_id`, but its logo view requests Logo.dev by name for every subscription without a catalogued ID. That lookup returns only the provider's top result, which is unsafe for ambiguous or generic subscription names. The view also requests JPG and crops every response with `scaledToFill` inside a circle, producing white tiles and inconsistent visual weight.

The existing catalog already stores verified domains and `subscriptions` already permits authenticated updates. Logo.dev's CDN supports transparent PNG, theme selection, and URL query parameters, so the redesign does not require a new dependency or database migration.

## Goals / Non-Goals

**Goals:**

- Make every brand visual fit the Renewa card language without cropping provider artwork.
- Only display a remote logo automatically when it is associated with a verified catalog domain.
- Let a user explicitly choose a reviewed brand from the existing catalog for an otherwise unknown subscription.
- Persist a confirmed choice in the existing nullable `brand_id`, including from a lightweight edit action.
- Preserve the initial/category fallback for loading, error, legacy, and offline states.

**Non-Goals:**

- Calling Logo.dev's paid/server-side Search API, storing raw provider URLs, or guessing a logo from arbitrary user text.
- Adding a comprehensive subscription editor or a new database column.
- Extracting logo colors, modifying logo pixels, or shipping third-party logo binaries.

## Decisions

### Use a soft-squircle brand stamp with a contained image

The reusable icon will use a rounded rectangle matched to Renewa's field and card radii. The returned image is rendered as PNG with `scaledToFit` in a smaller interior frame, allowing transparent marks and wordmarks to retain their proportions. A neutral warm surface, subtle border, and shadow establish the frame; fallback initials use the same frame rather than a different shape.

Alternative: circle-crop a full-bleed image. This is compact but discards logo geometry and creates opaque-square artifacts for JPG responses.

### Trust verified domains; never automatically name-search unknown subscriptions

Only a stored catalog `brand_id` becomes a Logo.dev domain URL. A name that exactly resolves to a reviewed alias can set that ID during creation. All other names remain the Renewa fallback until the user explicitly chooses one of the reviewed catalog brands.

Alternative: preserve `/name/:name` as a fallback. It increases apparent coverage but can misidentify a service and is incompatible with a finance-oriented app's trust expectations.

### Make confirmation a local catalog picker and persist through PostgREST PATCH

The add form exposes a compact brand picker after the user enters a subscription name. An Overview context-menu action presents the same picker for existing rows. Saving a choice uses the existing owner-scoped Supabase update policy and updates the store in place. "Use subscription initial" clears `brand_id` and returns to the fallback.

Alternative: build remote search and selection. That needs a protected provider credential and candidate-ranking/backend design, which is not needed for the reviewed launch catalog.

### Version the logo URL as a presentation cache boundary

The image URL contains a static presentation version. Bumping it on a future visual migration changes the cache key without persisting provider URLs or requiring cache deletion. This forces the redesigned PNG treatment to replace previously cached JPEG responses.

Alternative: clear the shared URL cache. That is global, unpredictable, and can disturb other networking work.

## Risks / Trade-offs

- [Catalog coverage is intentionally limited] → Unknown services retain a polished fallback and users can choose only reviewed brands.
- [A user selects an unrelated brand] → The picker labels choices clearly and always offers the fallback; the selection is a reversible personal display preference.
- [Transparent logos have different intrinsic padding] → Contained rendering, a consistent interior frame, and visual inspection of the initial catalog reduce contrast between marks.
- [Provider/network failure] → The fallback stays visible throughout loading and errors; rows are never delayed.
- [Older image cache entries persist] → The versioned URL creates a new cache identity for this release.

## Migration Plan

1. Ship the client update; no SQL migration is required because `brand_id` and update RLS already exist.
2. Existing catalogued rows start using the versioned PNG domain URL; legacy and unknown rows retain their fallback.
3. Users can add or clear a confirmed brand choice through the picker.
4. Roll back by removing the new client UI; stored `brand_id` remains compatible with earlier releases.

## Open Questions

- The reviewed catalog currently contains eight brands. Additional entries should be added only with a verified domain and aliases, then visually reviewed in the stamp.
