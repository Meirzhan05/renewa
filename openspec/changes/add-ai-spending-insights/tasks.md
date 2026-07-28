## 1. Insight data foundation

- [ ] 1.1 Add an additive Supabase migration for `monthly_spend_snapshots` and `insight_reports`, including constraints, indexes, user ownership RLS, and authenticated read access.
- [ ] 1.2 Implement a reusable server-side monthly-commitment snapshot builder that groups active subscriptions by source currency and category.
- [ ] 1.3 Configure and document the production-safe monthly snapshot schedule, with current-period upserts after successful subscription mutations and email scans.
- [ ] 1.4 Add API decoding models and authenticated client methods for insight reports and historical snapshots.

## 2. AI insight service

- [ ] 2.1 Implement the authenticated `insights-refresh` Edge Function and build a bounded, user-scoped fact bundle from subscriptions, billing events, scan metadata, and snapshots.
- [ ] 2.2 Add DeepSeek structured-output generation that omits raw email content and uses the existing server-only model configuration.
- [ ] 2.3 Validate the generated schema and evidence references against the fact bundle before storing or returning a report.
- [ ] 2.4 Add report fingerprinting, expiry-based cache reuse, explicit refresh behavior, and deterministic fallback responses for unavailable or invalid AI output.
- [ ] 2.5 Add Function tests for authentication, cross-user isolation, cache behavior, sensitive-field omission, invalid model output, and provider failure fallback.

## 3. Insights experience

- [ ] 3.1 Extend `AppStore` with insight loading, refresh state, report data, snapshot data, and exchange-rate handling for historical source currencies.
- [ ] 3.2 Replace the static Insights layout with a deterministic overview and an AI summary area that identifies the data basis and supports retry.
- [ ] 3.3 Build an accessible category-composition chart using Swift Charts with text values and independent empty-state handling.
- [ ] 3.4 Build a chronological upcoming-30-day renewal timeline with accessible labels, amounts, and no-renewals state.
- [ ] 3.5 Build a historical monthly-commitment trend chart that uses only persisted usable snapshots and clearly communicates insufficient history or unavailable conversion.
- [ ] 3.6 Honor Dynamic Type, VoiceOver descriptions, Reduce Motion, loading, error, and offline states across all insight components.

## 4. Validation and rollout

- [ ] 4.1 Add XCTest coverage for fact presentation models, snapshot conversion, chart states, and AI fallback behavior.
- [ ] 4.2 Apply migrations to a local Supabase instance, exercise snapshot/report RLS as authenticated users, and verify no report leaks across accounts.
- [ ] 4.3 Build the simulator and device targets, manually verify the Insights states with empty, single-currency, foreign-currency, and sparse-history data.
- [ ] 4.4 Document required server secrets, scheduler setup, cache/refresh behavior, and rollback steps without committing secrets.
