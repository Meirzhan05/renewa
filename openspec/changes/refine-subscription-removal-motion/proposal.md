## Why

The current deletion motion gives an ordinary subscription row a pronounced 3D rotation, blur, and sideways throw. It feels busier than the rest of Renewa's calm, record-like interface and distracts from the successful completion feedback.

## What Changes

- Replace the home subscription row's 3D tuck animation with a quiet two-stage dismissal: a brief settle followed by a vertical collapse and list reflow.
- Remove blur, perspective rotation, and large horizontal movement from the normal-motion path.
- Keep failure recovery visibly distinct and make Reduced Motion a concise fade with no transform-driven motion.
- Retain the existing deletion request timing, haptic feedback, and confirmation toast behavior.

## Capabilities

### New Capabilities

- `subscription-removal-motion`: Calm, accessible lifecycle motion for removing and recovering home-page subscription rows.

### Modified Capabilities

- None.

## Impact

- Updates home-page transition and animation code in `Renewa/OverviewView.swift`.
- Does not alter the Supabase deletion API, subscription model, persistence behavior, or navigation.
