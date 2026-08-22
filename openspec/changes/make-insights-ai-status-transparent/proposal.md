## Why

Insights currently presents AI-generated and deterministic fallback summaries in nearly the same way. A user cannot tell whether Renewa successfully used its AI service, how current the result is, or why a basic summary is being shown, which makes the feature feel unconnected and untrustworthy.

## What Changes

- Identify each Insights summary as AI-generated, cached AI-generated, deterministic, unavailable, or not applicable because no active subscriptions exist.
- Show privacy-safe freshness and evidence context alongside a successful or deterministic summary.
- Keep deterministic charts and subscription facts available when the AI service is unavailable, while replacing ambiguous loading or generic failure states with a clear, retryable AI-specific state.
- Preserve the existing server-side validation, 24-hour cache, and deterministic fallback; add only the response metadata needed for the client to accurately represent its source and availability.
- Add operationally safe diagnostics for AI generation and fallback outcomes without retaining prompts, email content, or secret values.

## Capabilities

### New Capabilities

- `insights-ai-provenance`: Communicate the source, freshness, evidence scope, and degraded availability of an Insights summary without misrepresenting a fallback as AI output.

### Modified Capabilities

- None.

## Impact

- Affects the `insights-refresh` Edge Function response and cached insight report payload.
- Affects `InsightReport`, Insights loading/error presentation state, and the AI summary portion of `InsightsView`.
- Adds backend and client test coverage for AI success, cached output, deterministic fallback, unavailable AI, and accounts with no active subscriptions.
- Does not expand email access, send raw inbox content to the Insights model, introduce financial advice, or expose provider errors or secrets to the user.
