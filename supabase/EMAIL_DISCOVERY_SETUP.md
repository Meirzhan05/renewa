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

## Inbox Intelligence experience

Inbox Intelligence is an assistant-first surface: its default view answers whether a person needs to review a subscription change. Healthy monitoring shows a compact status, connected-inbox chips, and a small **Handled for you** feed based on real, user-owned review outcomes and safe lifecycle decisions. Pending proposals appear as the primary review cards, and active scans show only the durable stage and checked-message count. Manual checks, provider connections, inbox-scan alerts, scan history, paused suggestions, privacy guidance, and non-actionable outcomes live in the overflow menu and related sheets so routine monitoring does not feel like a scanner dashboard. The screen never invents email counts, automatic subscription changes, price increases, or duplicate-charge findings when the backend has not produced them.

The authenticated scan-status response contains only privacy-minimized learning items: merchant label, event type, received date, lifecycle outcome, and a bounded explanation. These remain secondary and never appear as active subscriptions or required actions. The UI never includes raw email content, full mailbox addresses, OAuth credentials, or raw model output, and it never invents a scan completion percentage when a provider has no reliable total.

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
npx --yes deno@2.5.2 test supabase/functions/_shared/inbox-scan-dashboard.test.ts
```

## Hosted deployment

Apply migrations, upload secrets, and deploy the existing Functions:

```sh
supabase db push
supabase secrets set --env-file supabase/functions/.env
supabase functions deploy mail-oauth-start
supabase functions deploy mail-oauth-callback --no-verify-jwt
supabase functions deploy email-scan
supabase functions deploy inbox-monitor --no-verify-jwt
```

## Event-driven inbox monitoring

After a person explicitly connects an inbox, Renewa provisions a provider watch. Provider events are wake signals only: Gmail Pub/Sub and Microsoft Graph never provide the message content used for extraction. Renewa follows the established Gmail history or Microsoft delta cursor, filters metadata first, and retrieves full content only for likely billing messages.

Configure these server-only values before connecting a production inbox:

- `GMAIL_PUBSUB_TOPIC`: fully-qualified Google Cloud Pub/Sub topic, for example `projects/PROJECT_ID/topics/renewa-inbox-events`. Grant `gmail-api-push@system.gserviceaccount.com` publisher access to it.
- `GMAIL_PUBSUB_AUDIENCE`: the audience configured on the Pub/Sub push subscription, normally the public `inbox-monitor` Function URL.
- `GMAIL_PUBSUB_SERVICE_ACCOUNT`: the service account email configured for Pub/Sub OIDC push delivery.
- `INBOX_MONITORING_WEBHOOK_URL`: optional public HTTPS callback used by Microsoft Graph; it defaults to `<SUPABASE_URL>/functions/v1/inbox-monitor`.

Create a Pub/Sub push subscription to the deployed `inbox-monitor` URL with OIDC authentication. Register the same public HTTPS callback with Microsoft Graph; Graph validates it by POSTing a `validationToken`, which the Function returns as plain text. Do not put any of these values in the iOS app.

## Reconciliation and watch renewal

Set a random server-only `INBOX_MONITOR_SECRET` for the `email-scan` Edge Function. Then use the Supabase Dashboard SQL Editor to enable `pg_cron` and `pg_net`, store the same value in Vault as `INBOX_MONITOR_SECRET`, and schedule protected reconciliation and renewal calls. Keep the secret out of the iOS app and migrations.

```sql
select cron.schedule(
  'renewa-inbox-event-work',
  '*/2 * * * *',
  $$
  select net.http_post(
    url := 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/email-scan',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-renewa-monitor-secret',
      (select decrypted_secret from vault.decrypted_secrets where name = 'INBOX_MONITOR_SECRET')
    ),
    body := '{"action":"reconcile"}'::jsonb
  );
  $$
);

select cron.schedule(
  'renewa-inbox-watch-renewal',
  '15 * * * *',
  $$
  select net.http_post(
    url := 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/email-scan',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-renewa-monitor-secret',
      (select decrypted_secret from vault.decrypted_secrets where name = 'INBOX_MONITOR_SECRET')
    ),
    body := '{"action":"renew_monitoring"}'::jsonb
  );
  $$
);
```

The reconciliation command processes provider-event work every two minutes and also runs the existing daily cursor backstop for due inboxes. The renewal command refreshes watches before they expire. Both calls are protected by a server-only secret, process bounded batches, and use the existing retry/cursor logic for transient provider failures. Disconnecting an inbox deletes local monitoring state and attempts to remove the Microsoft subscription. People can still use **Check now** at any time.

## Operational checks

- Confirm Gmail OAuth verification for `gmail.readonly` and Microsoft delegated `Mail.Read`.
- Verify two connected providers create two jobs under one batch and a single-provider failure yields a partial result.
- Re-run a scan and confirm provider cursors advance without duplicate candidates.
- Confirm an old receipt followed by a later cancellation does not appear as an add candidate, and that a recent annual receipt remains current until its projected renewal.
- Confirm “I don’t use this” resolves pending non-cancellation candidates for a merchant and prevents future proposals without changing subscriptions.
- Confirm incremental scans remain Inbox-focused; do not treat the absence of a cancellation email as lifecycle proof.
- Confirm duplicate Gmail Pub/Sub and Microsoft Graph events create one due record, and an event received during an active scan creates one follow-up check.
- Confirm a missed provider event is discovered by the daily cursor reconciliation, an expired provider watch becomes degraded, and invalid OAuth becomes reconnect required.
- Confirm dashboard copy says inbox monitoring is active only after a verified provider watch has been provisioned.
- Confirm malformed JSON, wrong message IDs, impossible dates, unsupported currencies, and prompt-injection text never create actionable candidates.
- Confirm another authenticated user cannot read or review a candidate through RLS or Function ownership checks.
- Confirm repeated confirmation is idempotent and an ignored candidate never changes a subscription.
- Confirm disconnect deletes the encrypted connection even when remote revocation reports an expired token.
- Confirm account deletion cascades through sync state, jobs, runs, candidates, events, and confirmed subscriptions.
- Monitor candidate precision, field corrections, validation failures, model latency/cost, cursor fallback, partial scans, and provider throttling.
