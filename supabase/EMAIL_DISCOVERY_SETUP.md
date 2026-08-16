# AI Email Subscription Discovery

Renewa's inbox discovery is an authenticated, read-only, review-first pipeline:

1. The client starts a scan and receives a batch identifier immediately.
2. The Function creates one durable job per connected inbox and processes jobs through an Edge Runtime background task.
3. Gmail bootstraps a bounded mailbox window and then advances with `historyId`; Microsoft uses an Inbox messages `deltaLink`.
4. Bounded metadata and snippets select likely billing messages before any full body is retrieved.
5. One sanitized, truncated message is sent to the configured DeepSeek-compatible JSON extractor.
6. Runtime validation and deterministic merchant lifecycle reconciliation classify evidence as current, explicitly ended, or uncertain before a pending candidate is created.
7. Historical or uncertain receipts remain non-actionable; a later cancellation supersedes earlier receipt evidence.
8. Only an authenticated user confirmation applies an addition, update, or cancellation. A person can suppress future discovery suggestions for an unused merchant without changing a subscription.

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

## Daily automatic monitoring

After a person explicitly connects an inbox during onboarding, Renewa processes the existing inbox in resumable pages and then enables daily incremental monitoring for that connection. The daily monitor only follows the established Gmail history or Microsoft delta cursor; it does not re-run the historical scan or inspect full content unless a new message passes billing-signal filtering.

Set a random server-only `INBOX_MONITOR_SECRET` for the `email-scan` Edge Function. Then use the Supabase Dashboard SQL Editor to enable `pg_cron` and `pg_net`, store the same value in Vault as `INBOX_MONITOR_SECRET`, and schedule a daily call. Keep the secret out of the iOS app and migrations.

```sql
select cron.schedule(
  'renewa-inbox-monitor-daily',
  '15 3 * * *',
  $$
  select net.http_post(
    url := 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/email-scan',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-renewa-monitor-secret',
      (select decrypted_secret from vault.decrypted_secrets where name = 'INBOX_MONITOR_SECRET')
    ),
    body := '{"action":"automatic"}'::jsonb
  );
  $$
);
```

The monitor is protected by its server-only secret. It processes up to 100 due connections per run, marks each processed connection with `last_automatic_scan_at`, and starts durable jobs; the existing retry/cursor logic handles transient provider failures. Disconnecting an inbox stops all future monitoring. Users can still run a manual scan at any time.

## Operational checks

- Confirm Gmail OAuth verification for `gmail.readonly` and Microsoft delegated `Mail.Read`.
- Verify two connected providers create two jobs under one batch and a single-provider failure yields a partial result.
- Re-run a scan and confirm provider cursors advance without duplicate candidates.
- Confirm an old receipt followed by a later cancellation does not appear as an add candidate, and that a recent annual receipt remains current until its projected renewal.
- Confirm “I don’t use this” resolves pending non-cancellation candidates for a merchant and prevents future proposals without changing subscriptions.
- Confirm incremental scans remain Inbox-focused; do not treat the absence of a cancellation email as lifecycle proof.
- Confirm malformed JSON, wrong message IDs, impossible dates, unsupported currencies, and prompt-injection text never create actionable candidates.
- Confirm another authenticated user cannot read or review a candidate through RLS or Function ownership checks.
- Confirm repeated confirmation is idempotent and an ignored candidate never changes a subscription.
- Confirm disconnect deletes the encrypted connection even when remote revocation reports an expired token.
- Confirm account deletion cascades through sync state, jobs, runs, candidates, events, and confirmed subscriptions.
- Monitor candidate precision, field corrections, validation failures, model latency/cost, cursor fallback, partial scans, and provider throttling.
