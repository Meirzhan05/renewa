## Why

Insights currently presents a zero commitment and several disconnected empty cards when Renewa has no usable subscription data. This makes a first-time user experience look like a completed but uninformative dashboard instead of clearly explaining how to unlock useful insights.

## What Changes

- Add a unified first-time Insights state that explains the value of the page before any subscriptions, snapshots, or insight report exist.
- Provide contextual actions to add a subscription manually or continue to inbox discovery.
- Avoid presenting `$0` or an unavailable visualization as if it were a verified financial insight when there is no underlying data.
- Distinguish setup-required states from valid outcomes such as no upcoming renewals, history that is still accumulating, unavailable currency conversion, and a temporarily unavailable insight service.
- Preserve useful historical or deterministic content when a user has evidence but no current active subscriptions.
- Keep empty and partial states accessible under Dynamic Type, VoiceOver, and Reduce Motion.

## Capabilities

### New Capabilities

- `insights-empty-state`: Define the first-time Insights experience, its activation actions, and honest section-level states for incomplete, unavailable, and valid zero-result data.

### Modified Capabilities

None.

## Impact

- Affects the state selection and presentation in `Renewa/InsightsView.swift`.
- May require a shared app-level action or navigation route in `Renewa/RootView.swift` so Insights can open the existing add-subscription flow or select the Inbox tab.
- May add derived presentation state in `Renewa/AppStore.swift` to distinguish absent data from partial currency conversion and retained historical evidence.
- Requires UI and presentation-model coverage for first-time, partial-history, no-renewal, unavailable-conversion, and service-failure states.
- Does not require database migrations, new backend APIs, broader mail scopes, or changes to insight-generation privacy boundaries.
