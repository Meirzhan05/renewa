## Context

`InsightsView` currently renders its annual commitment and each visualization independently once the initial deterministic load finishes. When an account has no subscription evidence, that produces a `$0` commitment followed by multiple unavailable cards, while the only visible page action refreshes the same empty dataset. The global add-subscription sheet and Inbox tab are owned by `MainTabView`, so Insights cannot currently invoke either contextual next step.

The existing Insights work already separates deterministic charts from an optional AI report and defines honest insufficient-history behavior. This change refines the client presentation without changing stored data, backend APIs, model generation, or privacy boundaries.

## Goals / Non-Goals

**Goals:**

- Give truly new users one coherent explanation and two useful activation actions.
- Prevent absent or partially convertible data from appearing as a complete zero-valued financial fact.
- Preserve real historical, report, or inactive-subscription context instead of treating returning users as new.
- Give waiting, positive-zero, conversion, and failure states distinct language and visual treatment.
- Keep the experience accessible and consistent with Renewa's existing theme and motion.

**Non-Goals:**

- Generate sample financial values or simulated charts.
- Change snapshot capture, currency-rate retrieval, insight report generation, or caching.
- Add a general-purpose navigation coordinator.
- Redesign charts that already have sufficient data.

## Decisions

### Classify a unified activation state from existing evidence

Insights will show its activation experience only after the initial Insights requests resolve and the store has no subscriptions, spending snapshots, or insight report. While this classification is unresolved, the existing delayed skeleton remains visible.

Any retained subscription record, dated snapshot, or report counts as evidence and keeps the user in the normal dashboard. This is preferred to checking only active subscriptions because a user who canceled everything may still have meaningful history.

### Replace the empty dashboard, not every partial state

The unified state replaces the commitment, AI, trend, category, and renewal stack only for a truly empty account. Once any evidence exists, sections continue to load independently and use contextual local states.

This hybrid is preferred to permanently showing a dashboard preview because repeated empty cards create visual noise. It is preferred to hiding all incomplete sections because history accumulation and quiet renewal periods are useful facts.

### Route contextual actions through closures owned by the tab container

`MainTabView` will provide `InsightsView` with an add action that opens its existing `AddSubscriptionView` sheet and an inbox action that selects the Inbox tab using the existing animated tab transition.

This is preferred to introducing a global route model because there are only two local actions and the parent already owns both destinations. It also avoids duplicating the add flow inside Insights.

### Present abstract benefits without fake data

The activation card will use existing Heroicons, theme colors, and simple SwiftUI shapes to suggest category, trend, and renewal analysis. It will not display sample currency amounts, dates, percentages, or chart axes.

This gives the empty state a purposeful visual identity without risking confusion between demonstration data and the user's finances.

### Make conversion completeness explicit

The commitment and category presentations will use the store's existing unavailable-conversion count. If every active subscription is unconvertible, the commitment will be described as unavailable rather than zero. If only some are unconvertible, any displayed total or category chart will state that it excludes those subscriptions.

Trend states will similarly distinguish insufficient dated history from history that exists but cannot currently be converted.

### Give section states distinct semantics

Local state cards will include a concise title and explanation:

- insufficient snapshots are described as history building;
- no upcoming renewals are framed as a quiet, positive result;
- no active subscriptions are framed as no current commitments while retained history remains available;
- unavailable conversion and service failures are framed as retryable limitations.

Refresh remains available for established dashboards and is hidden from the truly empty activation state, where refreshing cannot create evidence.

## Risks / Trade-offs

- [The activation state briefly flashes before report loading completes] → Keep the skeleton until both deterministic and report state are resolved when no other evidence exists.
- [Adding contextual actions duplicates the central plus button] → Use the same parent-owned sheet and treat the in-card action as explanatory onboarding, not a separate creation flow.
- [Partial totals remain easy to misread] → Place conversion-exclusion copy directly below the number or chart rather than relying on a distant global error.
- [A returning user with only inactive records sees sparse content] → Show an explicit no-current-commitments card and preserve any available history instead of reverting to first-time onboarding.
- [Decorative empty-state visuals become noisy under accessibility settings] → Hide decorative shapes from VoiceOver, provide combined labels, support Dynamic Type, and use the existing reduced-motion entrance path.

## Migration Plan

1. Add presentation-state classification and contextual state copy without altering backend data.
2. Pass the existing add and tab-selection actions from `MainTabView` into Insights.
3. Replace the truly empty dashboard with the unified activation experience and refine partial states.
4. Verify empty, inactive-only, sparse-history, conversion-unavailable, service-failure, and populated states.

Rollback is client-only: restore the prior independent section rendering and remove the two closures. No persisted data or server deployment requires rollback.

## Open Questions

- Should a future iteration remember that a user dismissed inbox discovery, or should both activation actions remain equally visible?
- Should the normal Insights header eventually replace manual refresh with a freshness timestamp once report caching is more visible?
