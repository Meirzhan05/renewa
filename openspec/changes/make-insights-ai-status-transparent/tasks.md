## 1. Insight response provenance

- [x] 1.1 Define backward-compatible Insight report provenance and privacy-safe evidence-summary models for the Edge Function and Swift client.
- [x] 1.2 Update `insights-refresh` to attach AI/deterministic source, server generation time, aggregate evidence counts, and response cache status for every non-null report.
- [x] 1.3 Preserve the validated deterministic fallback and 24-hour cache behavior, emit privacy-minimized outcome diagnostics, and ensure forced refresh bypasses cache lookup.
- [x] 1.4 Add Edge Function tests for fresh AI output, cache reuse, fallback after generation/validation failure, forced refresh, and no-active-subscription behavior.

## 2. Insights presentation

- [x] 2.1 Decode and retain report provenance in the app store without clearing a visible report during a refresh.
- [x] 2.2 Redesign the Insight summary card to show truthful source, cached/fresh status, relative generation time, and meaningful aggregate evidence counts.
- [x] 2.3 Present deterministic fallback as a scoped AI-unavailable state with a forced retry action while retaining deterministic dashboard sections.
- [x] 2.4 Ensure full request failure, no-active-subscription activation, Dynamic Type, VoiceOver, and Reduce Motion remain distinct and accessible without provider-specific error text.

## 3. Verification and rollout

- [x] 3.1 Add XCTest coverage for provenance labels, evidence-count omission, forced retry, retained-content refresh, and no-AI activation.
- [ ] 3.2 Run Edge Function tests plus simulator/device builds, and manually verify fresh AI, cached AI, fallback, retry, and failure variants.
- [x] 3.3 Update `todo.md` and the Insights/AI setup documentation with provenance semantics, privacy guarantees, and deployment order.
