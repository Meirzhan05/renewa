## Why

Subscription logos currently vary in quality because every unresolved name can use a best-effort provider lookup, while the returned image is cropped into a circular frame and requested as JPG. This can show an incorrect company, flatten transparent artwork onto a white square, or make a real logo feel visually disconnected from Renewa's soft card design.

The app should treat a logo as trusted supporting context, not an unverified identity. A more deliberate visual frame and a confirmation path will make the subscription list calmer, more legible, and more trustworthy.

## What Changes

- Replace the full-bleed circular image treatment with a Renewa-aligned soft-squircle brand stamp that centers logos with consistent safe space and no cropping.
- Request transparent logo imagery and use light-theme rendering where appropriate so dark marks remain legible on Renewa's warm surfaces.
- Automatically display remote logos only for catalogued services with verified domains; preserve the familiar initial/category fallback for unknown services instead of accepting an unverified first search result.
- Provide a user-confirmed logo selection path while creating or editing an unknown subscription, and persist the selected stable brand reference.
- Version or invalidate prior remote image URLs when the presentation changes so stale provider images do not survive the redesign.
- Maintain accessible subscription-name labels and the existing offline/error fallback behavior.

## Capabilities

### New Capabilities

- `subscription-logo-presentation`: Presents verified subscription logos in a consistent Renewa brand stamp, protects users from incorrect automatic matches, and supports explicit user confirmation for unknown services.

### Modified Capabilities

- None. The earlier `subscription-brand-logos` work is still an active, unarchived change rather than a published baseline capability.

## Impact

- Affected iOS UI: `SubscriptionBrandIcon`, subscription rows, add-subscription preview, and the subscription editing flow.
- Affected configuration/networking: Logo.dev image URL parameters and image-cache identity; Logo.dev remains the provider with its existing attribution requirements.
- Affected data model and backend only if confirmed selections need new reviewed brand entries or a durable override beyond the current nullable `brand_id`.
- Requires visual verification across transparent, dark, wide-wordmark, missing, offline, and legacy cached-logo states.
