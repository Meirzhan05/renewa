## Why

Renewa currently shows a static category breakdown and a generic reminder, so it cannot explain meaningful changes in a user’s subscription commitments or help them prepare for upcoming charges. Adding privacy-conscious AI summaries and purpose-built graphs will turn existing subscription and email-derived billing data into timely, understandable decisions.

## What Changes

- Add an Insights data foundation that derives auditable spending, renewal, category, and detected-billing-event facts from the user’s stored data without sending raw inbox content for insight generation.
- Add cached, structured AI insight summaries and recommendations generated server-side from those facts, with supporting evidence and graceful deterministic fallbacks.
- Add an Insights dashboard with a category composition graph, an upcoming-renewal timeline, and an historical monthly-spending trend graph.
- Record monthly spending snapshots so trend graphs and AI claims about change over time are based on retained history rather than reconstructed guesses.
- Explain the data basis for AI-generated cards and let users refresh insights explicitly.

## Capabilities

### New Capabilities

- `ai-spending-insights`: Generate, cache, and present evidence-backed AI insight cards from structured subscription and billing-event data.
- `subscription-spending-history`: Persist and expose monthly subscription-spend snapshots for historical comparison.
- `insights-visualization`: Present accessible category, renewal, and spending-trend visualizations in the iOS Insights experience.

### Modified Capabilities

None.

## Impact

- Affects `Renewa/InsightsView.swift`, `AppStore.swift`, `SupabaseClient.swift`, and new Swift models/views for insights and charts.
- Adds Supabase migrations, RLS policies, and a server-side Edge Function using the existing DeepSeek configuration for structured insight generation.
- Uses stored subscriptions, detected billing events, and scan metadata; it does not widen mail OAuth scopes or transmit email bodies for this feature.
