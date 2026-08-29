## Context

The inbox scan runs as: edge fetches a mailbox window → enqueues a `scan_jobs` row → the persistent
worker runs Tier-1 triage → the Tier-2 autonomous agent (`buildAgentGraph`) searches / fetches /
computes cadence / reconciles / `propose`s. The agent's only evidence is what its read executor
serves.

Today that evidence is **snippet-only**, in two compounding places:
- `supabase/functions/email-scan/index.ts` fetches mail with `fetchGmailMetadata` (`format=metadata`)
  and enqueues `raw_messages: providerBatch.metadata` — subject/sender/date + Gmail's ~200-char
  snippet, **no body**. (`fetchGmailFullMessage` with `format=full` exists in the same file but is not
  used for the worker handoff.)
- `worker/src/agent/pipeline.ts` `createScanReadExecutor` serves `fetch` with `content: meta.snippet`
  — so even when the agent spends its budget on `fetch`, it gets the snippet back.

The dev tracer `scripts/gmail-agent-trace.ts` is the control: it wires the SAME agent to
`createGmailReadExecutor` (Gmail `format=full` on `fetch`) and proposes ChatGPT and Claude correctly.
So the fix is to give the production agent the same on-demand full-body read.

The edge enqueue does **not** currently store the connection's access token on `scan_jobs`, so the
worker has no credential to read Gmail with — that gap must be closed too.

## Goals / Non-Goals

**Goals:**
- The worker's `fetch` tool returns the real sanitized full body from Gmail, on demand, for the
  messages the agent chooses to fetch.
- Reads are sparing (only fetched messages) and never fail the scan — snippet fallback on any error.
- No request/response contract change; no DB migration.

**Non-Goals:**
- Microsoft/Outlook full-body reads (keeps snippet-only; separate follow-up).
- Pre-fetching all bodies into `raw_messages` (the rejected alternative — see D1).
- Refresh-token handling in the worker for long-running scans (access-token-only; see D2/R1).
- At-rest encryption / JIT handling of the stored token (pre-existing deferred hardening, migration
  0001 — unchanged here, see R2).
- Moving Tier-1 triage into the edge.

## Decisions

**D1 — Worker fetches bodies on demand (chosen) over edge pre-fetch.**
The worker's `fetch` tool calls Gmail `format=full` only for the handful of messages the agent
actually opens. Rationale: keeps `scan_jobs` payloads small, reads bodies only for examined messages,
and mirrors the already-proven `gmail:trace` path. *Alternative rejected:* the edge pre-fetching every
body into `raw_messages` bloats queue rows, fetches bodies for messages the agent never looks at, and
adds a `format=full` call per message up front.

**D2 — Reuse the token the edge already holds; persist it on `scan_jobs.access_token`.**
The edge already has `tokens.access_token` (it uses it to fetch the window). It writes it onto the
enqueued row; the worker reads `ScanJob.accessToken`. The column already exists. No refresh token is
stored, so the token is the short-lived (~1h) access token; the worker claims the job within seconds
of enqueue, so it is fresh in the normal path.

**D3 — Graceful snippet fallback, never fail.**
`fetch` falls back to `meta.snippet` on: no token, non-Google provider, HTTP non-2xx (401/expiry), or
a parse error. This matches the codebase's degrade-don't-abort stance (triage admits wholesale on
outage; verify/classifier pass through on error). The change can therefore only add recall.

**D4 — One shared, pure body sanitizer.**
Move `extractGmailBody` (MIME walk: prefer `text/plain`, else stripped `text/html`) and `sanitizeBody`
(collapse whitespace, strip 200+ char base64/tracking blobs, cap at 6000 chars) out of
`scripts/gmail-client.ts` into `worker/src/domain/gmail-body.ts`. Both the script and the worker
executor import them, so the untrusted-content wall has exactly one implementation.

**D5 — Provider scope = Gmail only.**
`createGmailBodyReadExecutor` is used only when `provider === "google"` and a token is present;
everything else keeps `createScanReadExecutor`. Microsoft body reads are a follow-up.

**D6 — Read via raw `fetch` + Bearer token, not an OAuth2 client.**
The body read is a plain `GET https://gmail.googleapis.com/gmail/v1/users/me/messages/{id}?format=full`
with `Authorization: Bearer <access_token>` — the same shape the edge already uses. No `googleapis`
`OAuth2Client` construction is needed for a bare access token, keeping the worker's hot path light.

## Risks / Trade-offs

- **Token expires mid-scan (or the job waited in queue > ~1h)** → `fetch` returns 401 → snippet
  fallback for those messages → recall dips to today's behavior, scan still completes. → Mitigation:
  worker claims jobs within seconds; fallback covers the rest; refresh-token support is a named
  non-goal.
- **Storing a live Gmail access token at rest in `scan_jobs`** widens exposure of a sensitive
  credential. → Mitigation: it is the user's own read-only (`gmail.readonly`) token, used only to read
  that user's own inbox, never sent anywhere external. At-rest encryption / JIT is the pre-existing
  deferred hardening noted in migration 0001; this change does not weaken it further, and the column
  was created for exactly this use.
- **More untrusted body text now reaches the model** → larger prompt-injection surface. → Mitigation:
  system prompts already treat email as untrusted data and forbid following it; `sanitizeBody` strips
  markup and blobs; the `propose.ts` anti-exfil wall is unchanged (only typed, validated fields reach
  the human card — no free-text passthrough).
- **Extra Gmail API calls** (one `format=full` per fetched message) → latency/quota. → Mitigation:
  bounded by the agent's `maxFetches` budget; `search` stays metadata-only over the window.
- **The edge half is Deno** → cannot be `deno check`'d or run in this environment → ships blind. →
  Mitigation: the edit is a single field on an existing insert; the user runs `deno check` + redeploy
  + a smoke test before trusting it.

## Migration Plan

1. Land the worker changes (no migration — `scan_jobs.access_token` already exists). With an
   already-enqueued (token-less) job the worker simply uses the snippet fallback, so old queued jobs
   still run.
2. `deno check supabase/functions/email-scan/index.ts`, then redeploy the edge so new scans persist
   the token.
3. Smoke test: with the worker running, scan an inbox containing ChatGPT/Claude receipts and confirm
   they now surface as candidates.

**Rollback:** revert the commits. Because the worker degrades to the snippet when no token/`fetch`
fails, reverting only the edge (leaving the worker) is also safe — the worker just stops getting
bodies and returns to today's behavior.

## Open Questions

- Should the edge additionally store a refresh token and the worker refresh it, to cover long scans?
  (Deferred; access-token-only is sufficient for the normal fast-claim path.)
- Should Microsoft/Outlook get an equivalent on-demand body reader? (Deferred; Gmail is the immediate
  need.)
