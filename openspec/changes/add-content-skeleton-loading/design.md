## Context

Renewa uses `ProgressView` for app launch, a loading AI-summary card, and most save/scan actions. The app already has a warm, low-contrast palette (`RenewaTheme`) and respects Reduce Motion in its entrance transitions, but it has no reusable representation of content loading or separate state for an initial content load versus a background refresh. Insights can render deterministic charts independently from its asynchronous AI report, while Overview data is loaded before the app enters `.ready`.

## Goals / Non-Goals

**Goals:**

- Make known content layouts feel present before data arrives without implying that content exists.
- Keep loaded data readable and interactive while a refresh is in progress.
- Use one reusable visual language with a static accessible reduced-motion mode.
- Replace spinner-only primary-action feedback with stable labels that describe the current operation.

**Non-Goals:**

- Add a third-party loading or animation dependency.
- Change Supabase requests, persistence, authentication, or subscription business rules.
- Use skeletons for empty, error, confirmation, or destructive-action states.
- Hide every short operation behind a placeholder; fast work must not visibly flash a loading treatment.

## Decisions

### Shared layout primitives, not a global overlay

Add a small `RenewaSkeleton` view/modifier in the shared theme layer. It will render rounded warm blocks using `surface` and `divider` colors and provide text-line, icon, card, chart, and subscription-row compositions where required. Layout-specific skeleton views remain near their feature views so their geometry tracks the real UI.

This is preferred to a global full-screen overlay because each screen exposes different expected structure and users retain context. It is preferred to a package because SwiftUI shapes and the existing theme are sufficient.

### Gentle opacity pulse with a delayed presentation

The shared primitive will begin a low-amplitude opacity pulse only after a short delay (roughly 250 ms) so quick requests do not flicker. The animation is disabled when `accessibilityReduceMotion` is enabled; the placeholder remains visible and static. Skeleton elements will be hidden from VoiceOver and their containing region will announce a concise loading label.

This is preferred to a fast shimmer sweep, which would conflict with Renewa’s understated motion and can be distracting. A delayed presentation is preferred to instantly displaying placeholders on every request.

### Progressive Insights rendering

Represent Insights’ deterministic-data load separately from AI-report generation. While the first Insights load is unresolved, show a commitment-card, AI-card, trend, category, and renewal skeleton matching the final vertical layout. Once deterministic subscription data is present, render cards and graphs immediately; only the AI card presents an updating state while a forced refresh runs. Existing report content remains visible until replacement succeeds, with an accessible “Updating insights” status near refresh.

This is preferred to using the existing `isLoadingInsights` flag as a page-wide blanking signal, because data charts can be useful before DeepSeek finishes and prior results are better than an empty screen during refresh.

### Content skeletons only where structure is known

Subscription rows use a finite set of row placeholders only during a true initial collection load. The launch screen remains a brief branded transition rather than a fabricated dashboard. Empty/error views retain their existing explanatory content and never render skeletons.

This avoids treating all waiting states alike and protects against misleading users about absent subscriptions.

### Action status stays inside the initiating control

For auth, onboarding, email scanning, subscription creation, profile updates, deletion, and logo selection, retain the original button geometry, disable duplicate submission, and replace its ordinary icon/label with a task-specific label such as “Creating account…”, “Saving…”, or “Scanning…”. A compact accessible progress indication can supplement the label but is not the only signal.

This is preferred to inline skeletons in buttons because an action has no future content geometry to preview and the initiating control provides the clearest ownership and status.

## Risks / Trade-offs

- [Skeleton geometry drifts from the loaded view] → Keep feature-specific compositions adjacent to the real view and verify them in simulator screenshots.
- [Repeated task starts cause skeleton flicker] → Delay presentation and avoid clearing already-loaded content for refreshes.
- [Low contrast makes placeholders invisible] → Use tokenized color contrast that remains perceptible against `background` and test in light appearance.
- [VoiceOver announces decorative blocks] → Mark individual skeleton shapes hidden and expose one labelled loading region.
- [New store flags become inconsistent] → Define initial-load and refresh transitions in one `loadInsights` path and cover them with store tests when a test target is added.

## Migration Plan

1. Add the shared skeleton primitive and action-status helper without changing backend behavior.
2. Add the Insights load-state split and layout skeletons, then preserve data during refresh.
3. Apply action labels and any subscription-row skeletons to remaining surfaces.
4. Verify Reduce Motion, VoiceOver labels, fast/slow request behavior, and simulator/device builds.

Rollback is a client-only removal of skeleton rendering and new local load-state flags; no data migration or backend rollback is required.

## Open Questions

- Should Overview receive a first-load row skeleton immediately, or continue using the branded launch state until its initial data is ready?
- Which loading labels best match the final product voice: terse (“Saving…”) or descriptive (“Saving profile…”)?
