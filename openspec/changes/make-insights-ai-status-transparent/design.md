## Context

The deployed `insights-refresh` Edge Function builds a structured fact set from active subscriptions, detected billing events, the latest scan outcome, and spending snapshots. It attempts a DeepSeek JSON response, validates its cited identifiers, caches a resulting report for 24 hours, and silently substitutes a deterministic next-renewal summary if generation or validation fails.

The iOS client currently receives the report payload but not the response-level `cached` or `fallback` fields. It renders an AI report as “Renewa’s read” and any fallback as “Your subscription snapshot,” without explaining freshness, evidence scope, or the difference between a healthy fallback and a temporary service problem. A report is only requested for accounts with active subscriptions; empty accounts correctly remain in the existing Insights activation state.

## Goals / Non-Goals

**Goals:**

- Make the origin and freshness of every visible Insight summary intelligible without requiring users to understand providers or models.
- Preserve useful deterministic spending content and a valid cached report while a refresh is in progress or AI generation is degraded.
- Provide a retry path that bypasses a cache and retries the model without discarding the currently visible summary.
- Give operators enough outcome telemetry to distinguish successful AI generation, validation/provider failure, cache reuse, and deterministic fallback without logging prompts or email content.
- Retain the existing strict fact-only prompt, validation, read-only inbox boundary, and 24-hour report cache.

**Non-Goals:**

- Add an AI chat interface, financial recommendations, or automatic subscription actions.
- Send raw email bodies, OAuth tokens, secret values, or prompt text to the client or application logs.
- Claim an AI request succeeded merely because a deterministic fallback is available.
- Redesign the deterministic charts, empty Insights activation experience, or inbox scanning workflow.

## Decisions

### Carry explicit summary provenance from the backend response into the client model

`insights-refresh` will return a compact, typed provenance object with the report: source (`ai` or `deterministic`), cache status, generated timestamp, and privacy-safe evidence counts. The report payload retains `is_ai_generated` for backward compatibility, but the client will use the new provenance rather than infer state from labels.

The source is calculated server-side because only the function knows whether the cache was used and whether a fallback occurred. Sending only the existing boolean would incorrectly make a cached AI report indistinguishable from a newly generated one. The evidence summary contains only aggregate counts, such as active subscriptions and qualifying billing events; it excludes merchant names, raw messages, event contents, provider error text, and identifiers.

Alternative considered: infer source on-device from `is_ai_generated` and the generated timestamp. Rejected because the client cannot know whether the response came from cache or which inputs were safely considered.

### Represent AI availability as a scoped state, not a page failure

When a deterministic fallback is returned after an AI attempt, the summary card will identify itself as a “Basic subscription summary,” state that AI is temporarily unavailable, and offer a concise retry action. The card will not surface DeepSeek/model/validation error text. Deterministic commitment, trends, categories, and renewals continue to display.

If the full function request fails, the existing scoped Insights error treatment remains, but it must not replace deterministic dashboard sections when their local data loaded successfully. If there are no active subscriptions, Insights remains in its existing activation state and does not imply that AI is unavailable.

Alternative considered: show an AI error alert or use the generic “Renewa’s read” title for every fallback. Alerts create recurring noise, and generic wording erodes trust.

### Make freshness and evidence visible but subordinate to the insight

The summary card will lead with its useful text, followed by a compact provenance line such as “AI-generated · Updated 8 min ago” or “Basic summary · Updated today.” A second line will state aggregate evidence, for example “Based on 4 active subscriptions and 7 billing events,” only when those counts are meaningful. Cached AI output must explicitly say it is cached; a manual refresh displays a non-blocking updating indicator while preserving the prior report.

Relative timestamps are calculated on-device from the server-issued timestamp. This avoids treating device-local time as an authoritative generation time while keeping the interface readable.

Alternative considered: a detailed technical diagnostics panel. Rejected for the primary app because model/vendor names, provider errors, and request details do not help users act.

### Maintain cache correctness and force-refresh behavior

The existing 24-hour fingerprint cache remains the normal path. Its response will state when a matching AI or deterministic report was reused. A user-initiated refresh continues to send `force: true`, bypasses lookup of the prior cache, and retains the previous report in the UI until a new result or scoped degradation result arrives.

The database record will persist any report-level provenance required to faithfully render a cached report. Response-only cache status remains outside the persisted payload because it describes this delivery, not how the report was generated.

Alternative considered: always call the model when Insights opens. Rejected because it increases latency and cost, creates loading churn while switching tabs, and needlessly repeats equivalent analysis.

### Emit privacy-minimized outcome diagnostics

The Edge Function will log structured outcome categories and aggregate input counts: `cache_hit`, `ai_generated`, `ai_fallback`, `validation_failed`, or `request_failed`. It will not log authorization headers, secret names or values, request payloads, raw email content, merchant names, or model output. Error detail is retained only in protected platform logs as a categorized internal reason, never returned to the app.

Alternative considered: store detailed prompt and response logs in the database. Rejected because that adds sensitive retention without a product need.

## Risks / Trade-offs

- [A deterministic fallback may look less valuable than a model-generated summary] → Label it honestly but present the factual result prominently, with an unobtrusive retry.
- [Cache status can become confusing] → Use “cached” only for an otherwise AI-generated report and keep the generation timestamp visible.
- [An AI failure can be transient] → Preserve the force-refresh path and never overwrite a valid visible report until a replacement is available.
- [Evidence counts could expose more than intended on a shared screen] → Restrict them to coarse counts already represented by the account and omit zero-value metrics.
- [Provider errors can leak implementation details] → Categorize server-side diagnostics and map all user copy to stable, non-technical language.

## Migration Plan

1. Extend the function response and persisted report provenance with backward-compatible optional fields.
2. Deploy the updated function before the client; older clients continue to use the existing payload fields.
3. Release the client card presentation and retry behavior.
4. Verify AI, cached AI, deterministic fallback, function failure, and no-active-subscription paths with test fixtures and production-safe logs.

Rollback is safe: the client can ignore provenance fields, and the function can continue returning the existing report shape. No email data, OAuth scope, or destructive database migration is involved.

## Open Questions

- Should the fallback retry action be visible only after a known AI attempt fails, or also on all deterministic summaries generated before provenance existed?
- Do we want to display a broad “Last analyzed” timestamp elsewhere in Insights, or keep freshness scoped solely to the summary card?
