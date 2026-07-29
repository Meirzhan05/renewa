# AI Email Subscription Discovery

Renewa's inbox discovery is an authenticated, read-only, review-first pipeline:

1. The client starts a scan and receives a batch identifier immediately.
2. The Function creates one durable job per connected inbox and processes jobs through an Edge Runtime background task.
3. Gmail bootstraps a bounded mailbox window and then advances with `historyId`; Microsoft uses an Inbox messages `deltaLink`.
4. Bounded metadata and snippets select likely billing messages before any full body is retrieved.
5. One sanitized, truncated message is sent to the configured DeepSeek-compatible JSON extractor.
6. Runtime validation and deterministic merchant reconciliation create a pending candidate.
7. Only an authenticated user confirmation applies an addition, update, or cancellation.

Raw bodies and raw model responses are not stored. OAuth credentials remain encrypted in `email_connections`, which has no authenticated-client table privileges.

## Local setup

Copy `.env.example` to the ignored `.env`, provide the provider clients, a 32-byte mail encryption key, and the DeepSeek values, then reset the local database and serve Functions:

```sh
supabase db reset
supabase functions serve --env-file supabase/functions/.env
```

`supabase/config.toml` uses the `per_worker` Edge Runtime policy so background tasks can continue during local verification.

Run the pure extraction tests independently:

```sh
npx --yes deno@2.5.2 check supabase/functions/email-scan/index.ts
npx --yes deno@2.5.2 test supabase/functions/email-scan/email-discovery.test.ts
```

## Hosted deployment

Apply migrations, upload secrets, and deploy the existing Functions:

```sh
supabase db push
supabase secrets set --env-file supabase/functions/.env
supabase functions deploy mail-oauth-start
supabase functions deploy mail-oauth-callback --no-verify-jwt
supabase functions deploy email-scan
```

The first production release is deliberately on-demand. Starting or checking scan status resumes retryable user-owned jobs. If automatic retry without an active client becomes necessary, add a separately authenticated scheduled worker in a later change rather than exposing service-role processing through this client Function.

## Operational checks

- Confirm Gmail OAuth verification for `gmail.readonly` and Microsoft delegated `Mail.Read`.
- Verify two connected providers create two jobs under one batch and a single-provider failure yields a partial result.
- Re-run a scan and confirm provider cursors advance without duplicate candidates.
- Confirm malformed JSON, wrong message IDs, impossible dates, unsupported currencies, and prompt-injection text never create actionable candidates.
- Confirm another authenticated user cannot read or review a candidate through RLS or Function ownership checks.
- Confirm repeated confirmation is idempotent and an ignored candidate never changes a subscription.
- Confirm disconnect deletes the encrypted connection even when remote revocation reports an expired token.
- Confirm account deletion cascades through sync state, jobs, runs, candidates, events, and confirmed subscriptions.
- Monitor candidate precision, field corrections, validation failures, model latency/cost, cursor fallback, partial scans, and provider throttling.
