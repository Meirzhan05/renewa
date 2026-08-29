## 1. Shared Gmail body extraction (pure, unit-testable)

- [x] 1.1 Add `worker/src/domain/gmail-body.ts` exporting `extractGmailBody(payload)` (MIME walk:
      prefer `text/plain`, else stripped `text/html`, else a single text part) and `sanitizeBody(text)`
      (collapse whitespace, strip 200+ char base64/tracking blobs, cap at 6000 chars), plus the small
      decode helpers (`decodeB64Url`, `stripHtml`, `decodeEntities`). No `googleapis` import — operates
      on a plain Gmail message payload object. (Design D4.)
- [x] 1.2 Add `worker/test/gmail-body.test.ts`: text/plain preferred over html; html tags/style/script
      stripped; base64 blob replaced; length capped; HTML entities decoded; empty payload → "".

## 2. Worker Gmail read executor (on-demand full body)

- [x] 2.1 Add `worker/src/agent/gmail-read-executor.ts` exporting
      `createGmailBodyReadExecutor(accessToken, window): AgentReadExecutor`. `fetch` does
      `GET gmail/v1/users/me/messages/{id}?format=full` with `Authorization: Bearer <accessToken>`
      (id with the `gmail-` prefix stripped), returns `sanitizeBody(extractGmailBody(payload))` or the
      snippet on empty; on any non-2xx / thrown error returns `content: meta.snippet`. `search_inbox`
      matches over `window` (same as `createScanReadExecutor`). (Design D3, D6.)

## 3. Wire the executor into the production scan path

- [x] 3.1 `worker/src/agent/pipeline.ts` `runTwoTierScan`: accept optional `accessToken` and
      `provider` in `TwoTierDeps`; build the read executor as `createGmailBodyReadExecutor(accessToken,
      look)` when `provider === "google"` and a non-empty token is present, else the existing
      `createScanReadExecutor(look)`. (Design D5.)
- [x] 3.2 `worker/src/worker.ts` autonomous branch: pass `job.accessToken` and `job.provider` through
      to `runTwoTierScan`.

## 4. Edge: persist the access token on enqueue

- [ ] 4.1 `supabase/functions/email-scan/index.ts`: add `access_token: tokens.access_token` to the
      `scan_jobs` insert (~line 634), so the worker has a credential to read bodies with. (Deno — no
      local `deno check`; verified under task 6.3.)
      BLOCKED IN THIS ENV: the file is held open by a macOS Virtualization.framework process and
      returns EPERM to every editor here (even with the sandbox disabled), so this one line MUST be
      applied by hand on the host. Add `access_token: tokens.access_token,` inside the
      `admin.from("scan_jobs").insert({ ... })` object next to `user_id`/`provider`/`raw_messages`.

## 5. Share the sanitizer with the dev script

- [x] 5.1 `worker/scripts/gmail-client.ts`: import `extractGmailBody` / `sanitizeBody` / `decodeEntities`
      / `MessagePart` from `src/domain/gmail-body.ts` and delete the local copies; `createGmailReadExecutor`
      behavior unchanged (still uses `googleapis` for its OAuth flow). Verified by `tsc --noEmit`.

## 6. Tests + verification

- [x] 6.1 Add `worker/test/gmail-read-executor.test.ts`: with a stubbed `fetch`, a successful
      `format=full` returns the sanitized body; a non-2xx and a thrown error both fall back to the
      snippet; an unknown message id returns `message: null`; `search_inbox` returns window matches.
- [x] 6.2 `npm test` green — 85/85 (73 existing + 12 new), plus `tsc --noEmit` clean.
- [ ] 6.3 (ops — user runs; no local deno) `deno check supabase/functions/email-scan/index.ts`,
      redeploy the edge (with task 4.1 applied), then smoke test: with the worker running, a scan of an
      inbox containing ChatGPT/Claude receipts surfaces them as candidates.
