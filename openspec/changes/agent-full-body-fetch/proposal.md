## Why

The autonomous discovery agent judges every merchant from the email **subject plus a ~200-character
snippet only**: the edge function enqueues metadata-only `raw_messages`, and the worker's `fetch`
tool returns that snippet *as* the body. Subscriptions whose amount and renewal terms live in the
message **body** — notably Stripe-billed SaaS such as ChatGPT/OpenAI and Claude/Anthropic — therefore
lack the evidence to clear the agent's "propose only an explicitly recurring paid subscription" bar,
so they are silently missed. This is confirmed empirically: `npm run gmail:trace`, which fetches full
bodies, proposes both ChatGPT and Claude correctly (Anthropic at confidence 0.95 with amount/cycle/
renewal), while the production worker — snippet-only — surfaces neither. The agent's reasoning is
fine; production just starves it of evidence.

## What Changes

- The worker's `fetch` tool SHALL return the message's real, **sanitized full body**, retrieved from
  the Gmail API **on demand**, instead of echoing the snippet. Full-body reads happen only for the
  few messages the agent actually fetches (the budget already treats `fetch` as expensive/sparing).
- The edge function SHALL persist the connection's Gmail **access token** on the enqueued `scan_jobs`
  row so the worker has a credential to read with. The `access_token` column already exists
  (migration 0001) and is currently left null.
- When no usable body can be retrieved — no stored token, an expired/invalid token, a non-Google
  provider, or any Gmail error — the worker SHALL **fall back to the snippet**, degrading recall
  rather than failing the scan (consistent with the triage/verify/classifier degradation stance).
- **No change** to the `POST /functions/v1/email-scan` request/response contract, the iOS app, its
  poll loop, or the review queue. Provider scope is **Gmail (`google`)**; Microsoft keeps snippet-only
  for now.

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `inbox-scan-orchestration`: The agent's per-merchant evidence source is extended from snippet-only
  to the full sanitized message body, fetched on demand, with a snippet fallback. Adds the requirement
  that an enqueued scan carries the credential the worker needs to read bodies.

## Impact

- **Code:**
  - `worker/src/domain/gmail-body.ts` (new, pure) — MIME body extraction + sanitize helpers, moved
    from `scripts/gmail-client.ts` so the worker and the script share one implementation.
  - `worker/src/agent/gmail-read-executor.ts` (new) — `createGmailBodyReadExecutor(accessToken,
    window)`: `fetch` pulls `format=full` from Gmail and returns the sanitized body; `search` stays
    over the triaged window; snippet fallback on any error.
  - `worker/src/agent/pipeline.ts` + `worker/src/worker.ts` — use the Gmail executor when the job is
    Google and carries a token; otherwise the existing snippet executor.
  - `supabase/functions/email-scan/index.ts` — persist `access_token` on the `scan_jobs` insert.
    Deno: **cannot be `deno check`'d or run locally**; needs the user to `deno check` + redeploy.
  - `worker/scripts/gmail-client.ts` — import the shared helpers instead of its local copies.
- **Data:** uses the existing `scan_jobs.access_token` column — **no migration**. The token is stored
  roughly plaintext in dev; at-rest encryption / just-in-time handling remains the **pre-existing
  deferred hardening** already flagged in migration 0001 (not expanded here).
- **Dependencies:** none new — the body read uses a raw `fetch` with a Bearer token (same shape as the
  edge's `fetchGmailFullMessage`).
- **Behavior:** the agent gains real bodies for the messages it fetches → recovers body-only-signal
  subscriptions (ChatGPT/Claude and similar). The snippet fallback preserves today's behavior whenever
  a token is absent, so the change can only add recall, never remove it.
