## Why

Renewa currently uses generic progress indicators during content loading, which feel disconnected from the app’s calm, editorial interface and conceal the shape of the information that will arrive. Layout-aware skeletons and clearer action feedback will make waits feel intentional while preserving an honest distinction between loading, empty, stale, and failed data.

## What Changes

- Add a shared, accessible skeleton-loading system styled with Renewa’s warm surface palette and motion preferences.
- Show layout-matched skeletons for Insights content and subscription rows when the app is waiting for known data.
- Keep existing information visible during refreshes, with a concise updating state instead of blanking content or showing a page-level spinner.
- Replace indeterminate button spinners with stable in-button status labels and compact progress feedback for save, scan, authentication, onboarding, profile, and logo-selection actions.
- Preserve distinct empty and error states so placeholders never imply content that does not exist or hide a failed request.

## Capabilities

### New Capabilities

- `content-skeleton-loading`: Present accessible, layout-aware loading placeholders and progressive-refresh feedback across Renewa’s content surfaces.

### Modified Capabilities

- None.

## Impact

- Affects SwiftUI views including `InsightsView`, `OverviewView`, `RootView`, and existing action buttons in authentication, onboarding, subscription, email-scan, profile, and logo-picker flows.
- Adds shared SwiftUI loading components and explicit view-state handling in `AppStore` where a content load is not currently observable.
- No Supabase schema, Edge Function, external API, or credential changes.
