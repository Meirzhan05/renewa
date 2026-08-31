## Context

`MainTabView` currently infers a forward or backward direction from tab order and applies opposing horizontal movement to the outgoing and incoming screens. Home is the only primary tab hosted in a `NavigationStack`, which makes that screen behave differently during the directional transition.

## Goals / Non-Goals

**Goals:**

- Give every primary tab switch the same visual treatment.
- Keep the tab change responsive while avoiding navigation-like horizontal movement.
- Respect the system Reduce Motion setting.

**Non-Goals:**

- Change tab order, tab-bar layout, NavigationStack behavior, or the active-tab indicator animation.
- Change transitions within a tab, sheets, or navigation destinations.

## Decisions

- Use a symmetric fade combined with a modest scale transition for both insertion and removal. This applies equally to Home, Insights, Inbox, and Profile and removes stateful direction tracking.
- Keep an opacity-only transition for Reduce Motion. This retains feedback without translation or scale motion.
- Retain the existing spring timing for non-reduced motion. It already coordinates with the moving active-tab indicator; only the screen transition changes.

The alternative—normalizing every tab under a `NavigationStack` while keeping directional movement—would introduce unnecessary navigation containers and preserve a metaphor that does not fit non-hierarchical tab selection.

## Risks / Trade-offs

- [A scale transition can be too noticeable on dense screens] → keep the scale delta small and pair it with opacity.
- [Removing direction loses spatial cue] → the animated active-tab indicator continues to show which destination was selected.

## Migration Plan

1. Replace directional transition state and helpers in `MainTabView`.
2. Build the simulator target and manually verify switches to and from Home.
3. Revert the focused commit if the visual treatment is not preferred.

## Open Questions

- None.
