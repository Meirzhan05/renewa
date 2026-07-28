## 1. Shared loading foundation

- [x] 1.1 Add reusable warm, rounded skeleton primitives to the shared SwiftUI theme layer with a delayed low-amplitude pulse and a static Reduce Motion path.
- [x] 1.2 Add accessibility behavior that hides decorative skeleton shapes and announces a concise loading state for each skeleton region.
- [x] 1.3 Add a reusable primary-action progress presentation that preserves button geometry and supplies task-specific pending text.

## 2. Data-load state handling

- [x] 2.1 Separate initial Insights data/report loading from background report refresh state in `AppStore` without clearing previously successful content.
- [x] 2.2 Expose an initial subscription-collection loading state only for the period before the first collection response is available.
- [x] 2.3 Preserve existing empty and error states for completed empty and failed requests.

## 3. Content loading experiences

- [x] 3.1 Replace the Insights loading spinner with layout-matched commitment, insight, trend, category, and renewal skeletons.
- [x] 3.2 Render deterministic Insights data as soon as it is available and keep existing content visible with an updating cue during refresh.
- [x] 3.3 Add finite Overview subscription-row skeletons for the true initial collection load, without replacing the branded launch transition.

## 4. Action feedback refinement

- [x] 4.1 Update authentication and onboarding actions to use explicit in-button pending labels instead of spinner-only feedback.
- [x] 4.2 Update subscription creation, email scan, logo selection, profile update/currency selection, and account deletion actions with task-specific pending labels.
- [x] 4.3 Remove any remaining generic `ProgressView` that represents a known content layout or a primary-action-only status, while retaining appropriate platform-native refresh affordances.

## 5. Verification and documentation

- [ ] 5.1 Verify skeleton geometry, empty/error separation, slow-load behavior, and progressive refresh in the iOS simulator.
- [ ] 5.2 Verify Reduce Motion and VoiceOver loading labels for all new skeleton regions.
- [x] 5.3 Run device and simulator builds, update `todo.md`, and document the completed loading-state work.
