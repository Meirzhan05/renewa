## Why

A scan on 2026-09-03 read seven pages of the user's inbox successfully and then died on the eighth,
telling them to reconnect an inbox that was working perfectly:

```
pages 1-7   completed        14:23:02 → 14:24:18   (~8-11s each)
page 8      failed  1.2s     "Gmail could not be read. Reconnect your inbox."
run         failed           "One or more scan pages could not finish."
```

The connection was created at `14:22:51`, sixty seconds before the scan, with a token valid until
`15:22:50` and `last_error` empty. Reconnecting was not the fix and could not have been.

Two independent defects produced that outcome.

**Every provider failure is reported as an authorization failure.** `providerFetch`
(`index.ts:2573`) discards the HTTP status entirely:

```ts
if (!response.ok) throw new Error(failureMessage);
```

The message is fixed per call site, and the mailbox call sites pass
`"Gmail could not be read. Reconnect your inbox."`. So a `429`, a `500` and a genuine `401` are
indistinguishable — all three tell the user their inbox is disconnected. Worse, that text then feeds
`categorizeScanError`, whose `inbox-authorization` pattern matches on `/reconnect|token|bad request/`,
so the misdiagnosis is laundered into a user-facing category as though it had been classified. After
seven pages issuing two Gmail requests each in eighty seconds, a rate limit is the most likely
explanation for page 8 — and it is the one explanation the message rules out.

**The managed path does not retry.** The legacy `processUserJobs` retries a failed page twice with
backoff (`index.ts:738`, `retryable = job.attempts + 1 < 3`). The managed `processManagedConnection`
that now runs every scan (`index.ts:620`) has no equivalent: any error marks the job `failed`,
finalizes the run, and rethrows. Page 8 was on attempt 1. Under the old path it would have waited two
seconds and tried again — very likely successfully.

The result is that one transient provider hiccup discards an entire scan, and the user is sent to
re-authorize a healthy inbox.

## What Changes

- `providerFetch` classifies by HTTP status instead of discarding it. `401`/`403` are authorization
  failures; `429` is rate limiting; `5xx` is provider unavailability; other statuses are generic
  provider failures. The raw provider body is still never surfaced.
- Only a genuine authorization failure tells the user to reconnect. A rate limit says the provider is
  throttling and the scan will retry; an outage says the provider is unavailable.
- `scan-errors.ts` gains categories for rate-limited and provider-unavailable failures, so the
  distinction survives to the Inbox screen instead of collapsing into `inbox-authorization`.
- The managed page path retries a **retryable** failure with backoff before failing the run, matching
  the guarantee the legacy path already gives. An authorization failure is not retryable and fails
  immediately, as it should — retrying a revoked token only wastes time.
- A retry exhausts into the existing failure handling; nothing becomes silently ignored.

## Capabilities

### New Capabilities
- `provider-failure-classification`: a failed provider request is classified by what actually went
  wrong — authorization, rate limiting, provider outage, or other — and each is described to the user
  in terms of the thing they can act on, never as a blanket "reconnect your inbox".
- `page-retry-on-transient-failure`: a scan page that fails for a transient reason is retried with
  backoff before the run is failed, so one provider hiccup does not discard a scan that has already
  read most of an inbox.

### Modified Capabilities
None recorded in `openspec/specs/`.

## Impact

- `supabase/functions/email-scan/index.ts` — `providerFetch` (2573) returns a classified error; its
  nine call sites (2195-2481) stop passing "reconnect" text for non-auth failures;
  `processManagedConnection` (620) gains retry-with-backoff.
- `supabase/functions/_shared/scan-errors.ts` — new categories and messages; the
  `inbox-authorization` pattern narrows so it stops absorbing rate-limit and outage text.
- `supabase/functions/_shared/scan-errors.test.ts` and `email-discovery.test.ts` — classification and
  retry-decision coverage.
- `worker/src/trigger/scan-inbox-run.ts` and `worker/src/managed/edge-client.ts` — the managed step
  contract carries `retryAfterMs`, and `orchestrateManagedScan` waits it out with Trigger's durable
  `wait.for`. Required for the backoff to exist at all: that loop has no other delay.
- No schema change and no client change. Edge function deploy plus the worker.
- The Inbox screen's existing failure UI carries the new messages unchanged, since it renders
  whatever `userFacingScanError` returns.
