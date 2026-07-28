## Context

`InsightsView` currently calculates an annual commitment and category totals from active subscriptions on-device, then displays a generic reminder. The email-scan Edge Function already sends email content to DeepSeek solely to extract structured billing events; the resulting events, scan runs, and subscriptions are retained in Supabase. No historical commitment series or AI insight API exists.

This change adds data history, visualizations, and an explainable AI layer while preserving the current read-only mail scope and keeping model credentials on the server.

## Goals / Non-Goals

**Goals:**

- Deliver useful category, renewal, and trend visualizations from user-owned data.
- Generate concise, evidence-backed AI cards from a server-built fact bundle.
- Cache reports, handle model failures safely, and keep charts usable without AI.
- Persist enough data to support genuine historical comparisons.

**Non-Goals:**

- A free-form AI chatbot, automatic subscription cancellation, financial advice, or price forecasting.
- Sending raw emails, OAuth tokens, or unredacted email evidence to the insight generator.
- Adding mail providers or broadening existing OAuth scopes.

## Decisions

### Server-owned insight fact bundle

An authenticated `insights-refresh` Edge Function will query only the caller's subscriptions, detected billing events, scan-run metadata, and spending snapshots. It will calculate totals, category shares, upcoming renewals, and material changes before calling DeepSeek. It will send the model a bounded JSON fact bundle and accept only a strict JSON response containing a summary and evidence-linked cards.

This is preferred to creating prose on-device because model credentials and prompt controls remain server-side. It is preferred to resending emails because the structured event ledger is sufficient and materially safer.

### Report cache and deterministic fallback

`insight_reports` will persist the report payload, fact fingerprint, generation time, expiry, and model identifier per user. The Function returns a valid unexpired report for an unchanged fingerprint unless the caller explicitly requests refresh. If generation or validation fails, it returns deterministic computed facts without an AI report; the app continues to render charts and a neutral retry state.

### Historical commitment snapshots

`monthly_spend_snapshots` will store one user-owned snapshot per month and source currency, including total monthly commitment and category totals. A scheduled backend job creates the monthly snapshot; subscription mutations and scans may upsert the current period so a newly active account has a current data point. The client converts snapshot amounts using its existing currency conversion path and identifies unavailable conversion rather than inventing a combined total.

This is preferred to reconstructing old totals from current subscriptions because cancellations, price changes, and deleted subscriptions would make reconstructed history inaccurate.

### Native, accessible charts

The iOS client will use Swift Charts rather than a third-party graph library: a donut/category composition view, an upcoming-30-day renewal timeline, and a monthly commitment line/area trend. Chart content has text equivalents, category labels and values, Dynamic Type support, and a reduced-motion path. The page shows an honest empty or insufficient-history state for each independent visualization.

## Risks / Trade-offs

- [Model fabricates an interpretation] → Validate output schema and referenced event/subscription identifiers; render only server-calculated amounts and dates; label AI text as an explanation.
- [Sensitive data reaches the model] → Build a whitelist fact schema; omit email body, sender, subject, and free-text evidence; retain only short locally stored evidence labels for display.
- [AI latency or outage degrades the page] → Cache reports and make all charts deterministic and independently loadable.
- [Foreign-currency history cannot convert] → Retain source currency per snapshot and render unavailable values as unavailable rather than blending amounts.
- [Sparse historical data makes a trend misleading] → Require at least two dated snapshots and clearly state the available period.
- [Scheduled snapshots fail] → Upsert the current-period snapshot during successful scan and subscription changes, then surface missing-history gaps rather than interpolating.

## Migration Plan

1. Add snapshot and report tables, ownership RLS, indexes, and a controlled snapshot job.
2. Deploy the insight-refresh Function with the existing server-only DeepSeek secret and bounded input/output validation.
3. Ship client data models and charts behind empty/loading/failure states, then expose refresh after Function deployment.
4. Monitor Function failures and report freshness; rollback by hiding AI cards while retaining history and deterministic graphs. New tables are additive and do not alter subscriptions or mail connections.

## Open Questions

- What refresh cadence and report-expiry period best balance freshness against model cost?
- Should a future Settings control let a user disable AI generation while retaining deterministic graphs?
- Which scheduled-job mechanism is enabled for the production Supabase project (Cron/pg_cron versus an authenticated scheduled Function invocation)?
