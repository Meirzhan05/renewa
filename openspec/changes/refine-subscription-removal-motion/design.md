## Context

Home subscriptions are rendered as lightweight rows in a `LazyVStack`. Removal currently hides the selected row immediately, then applies a custom transition with perspective rotation, blur, horizontal movement, and vertical scaling while the backend deletion completes. The app's visual system otherwise favors gentle, low-amplitude motion and supports the system Reduce Motion setting.

## Goals / Non-Goals

**Goals:**

- Make removal read as a calm update to a financial record rather than an object thrown away.
- Preserve immediate feedback, smooth reflow of the remaining rows, failure recovery, haptics, and the existing success toast.
- Ensure motion-sensitive users receive a short opacity-only outcome.

**Non-Goals:**

- Add swipe-to-delete, an undo action, deletion confirmation, or backend changes.
- Change the deletion request, persistence timing, or context-menu commands.

## Decisions

- Use a two-stage removal transition: an approximately 80 ms settle (minor opacity and scale reduction) followed by a 180–220 ms vertical collapse. This provides acknowledgement before layout reflows without visual effects that compete with the content. A single fade was considered but does not sufficiently communicate where the removed row went.
- Remove 3D rotation, blur, and substantial horizontal offset. These effects imply a physical card and are disproportionate for a text-and-logo list row.
- Reuse the existing spring for stack reflow with a high damping fraction. The collapsed row and the following rows will therefore settle together without a bounce. A linear animation was rejected because it can make list movement feel abrupt.
- Use a compact opacity transition for both normal removal and recovery when Reduce Motion is enabled. Haptic feedback and the textual confirmation remain available because they do not require visual movement.
- Keep a subtle trailing-side recovery insertion when a deletion request fails. It differentiates recovery from initial loading while avoiding a dramatic reversal.

## Risks / Trade-offs

- [A row may appear to disappear before a slow network request completes] → Preserve the current immediate optimistic visual treatment and restore the row if the request fails.
- [A very short settle phase can be imperceptible on slower displays] → Keep the phase small but distinct through scale/opacity contrast rather than relying on a long delay.
- [Transition changes can affect new rows created elsewhere] → Scope the revised transition to home list deletion and verify failure recovery and normal list refresh behavior.

## Migration Plan

1. Replace the custom removal and recovery modifiers in `OverviewView`.
2. Verify normal deletion, failed deletion recovery, and Reduced Motion behavior in the simulator.
3. Roll back by restoring the previous transition modifiers; no data migration or service deployment is required.

## Open Questions

- None. The proposed motion intentionally keeps the current context-menu deletion trigger and confirmation toast.
