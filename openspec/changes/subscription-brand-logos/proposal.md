## Why

Subscription rows currently use a generated initial in a colored tile. This makes the dashboard less immediately recognizable, especially after email discovery, where a familiar service mark would help users scan and trust their subscription list.

## What Changes

- Add brand-logo metadata to subscriptions without removing the current initial-and-tint fallback.
- Introduce merchant normalization and a curated mapping for commonly recognized subscription services.
- Display logo imagery when a verified local or remote logo is available, with accessible labels and resilient loading states.
- Persist a resolved logo reference for manual and email-discovered subscriptions so the same service renders consistently across devices.
- Cache remote logo images on-device and avoid blocking the subscription list on a network request.
- Define source and usage constraints for third-party brand marks.

## Capabilities

### New Capabilities

- `subscription-brand-logos`: Resolves, persists, loads, caches, and displays recognizable subscription brand logos with a safe fallback.

### Modified Capabilities

- None.

## Impact

- Affects `Subscription` decoding/encoding, the Postgres `subscriptions` table, manual subscription creation, AI email ingestion, and the shared subscription-row UI.
- Adds bundled image assets and a client-side image-loading/cache path; may optionally integrate a licensed logo provider behind a configuration boundary.
- Requires a forward-only Supabase migration and verification of logo-source licensing, privacy, network reliability, and accessibility behavior.
