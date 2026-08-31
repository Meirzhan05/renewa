## Why

The directional tab animation makes Home feel different from the other tabs because it is the only tab hosted in a navigation container. Tab selection should feel consistent regardless of the selected destination.

## What Changes

- Replace directional tab movement with a uniform, lightweight fade-and-scale transition for every tab switch.
- Preserve an opacity-only transition when the user has Reduce Motion enabled.

## Capabilities

### New Capabilities

- `tab-navigation-motion`: Consistent, accessible motion for switching between primary application tabs.

### Modified Capabilities

- None.

## Impact

- Updates `Renewa/RootView.swift` and the tab-navigation task record in `todo.md`.
- Does not change the tab bar layout, app navigation destinations, or backend behavior.
