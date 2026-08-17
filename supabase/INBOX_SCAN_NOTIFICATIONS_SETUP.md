# Inbox scan notifications

Inbox Intelligence keeps scanning independent from notifications: a failed permission request, an expired device token, or an APNs outage never changes a scan result. Notifications contain only a terminal outcome, a count when review is needed, and a route back to Inbox Intelligence. They never contain email text, merchant names, model output, or access tokens.

## iOS setup

In the Apple Developer portal, enable **Push Notifications** for `com.renewa.app`, then create an APNs Auth Key. The Xcode target declares the Push Notifications entitlement and the application supports Live Activities. Build a signed app on a physical device to obtain an APNs device token; simulators do not validate ordinary remote-push delivery.

People opt in from **Inbox intelligence → Inbox scan alerts** after connecting an inbox. The setting requests system permission contextually, then records the current installation. A manual scan can show one Live Activity on that opted-in installation; automatic scans only deliver their final outcome notification. Turning alerts off stops new normal outcome notifications without preventing scanning.

## Server secrets and deploy

Create an APNs token key and keep the `.p8` value exclusively in Supabase secrets. Set these server-only values (replace placeholders):

```sh
supabase secrets set \
  APNS_BUNDLE_ID=com.renewa.app \
  APNS_KEY_ID=YOUR_APNS_KEY_ID \
  APNS_TEAM_ID=YOUR_APPLE_TEAM_ID \
  APNS_PRIVATE_KEY="$(cat AuthKey_YOUR_KEY_ID.p8)" \
  NOTIFICATION_DISPATCH_SECRET="$(openssl rand -hex 32)"

supabase db push
supabase functions deploy notification-settings
supabase functions deploy notification-dispatch --no-verify-jwt
supabase functions deploy email-scan
```

`notification-dispatch` rejects all requests without the `x-renewa-notification-secret` value. The iOS app never receives this secret. Use APNs sandbox for Debug installations and production for TestFlight/App Store installations; the saved installation environment chooses the endpoint.

Rotate the APNs Auth Key by uploading the replacement `APNS_KEY_ID` and `APNS_PRIVATE_KEY`, deploy no client change, verify a test delivery, then revoke the old Apple key. Rotate `NOTIFICATION_DISPATCH_SECRET` by updating Supabase/Vault and the scheduler in the same maintenance window.

## Scheduler

Enable `pg_cron`, `pg_net`, and Vault in the Supabase Dashboard. Store the dispatcher secret in Vault as `NOTIFICATION_DISPATCH_SECRET`, then schedule a short dispatcher run. The five-minute cadence bounds outcome latency while keeping retry work server-side.

```sql
select cron.schedule(
  'renewa-inbox-notification-dispatch',
  '*/5 * * * *',
  $$
  select net.http_post(
    url := 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/notification-dispatch',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-renewa-notification-secret',
      (select decrypted_secret from vault.decrypted_secrets where name = 'NOTIFICATION_DISPATCH_SECRET')
    ),
    body := '{}'::jsonb
  );
  $$
);
```

## Operations and rollback

Inspect queued outcomes, stuck leases, retry exhaustion, and disabled installations without exposing message data:

```sql
select event_type, status, attempts, available_at, locked_until, created_at
from public.notification_outbox
order by created_at desc
limit 50;

select platform, environment, is_enabled, invalidated_at, updated_at
from public.notification_device_installations
order by updated_at desc
limit 50;

select outcome, delivery_status, failure_reason, delivered_at
from public.notification_deliveries
order by created_at desc
limit 50;
```

To pause delivery immediately, disable the `renewa-inbox-notification-dispatch` cron job. Existing inbox scans continue. To roll back the product surface, hide the Inbox scan alerts control or disable the server preference; do not delete scan data. Re-enable the cron job after APNs credentials are repaired and confirm one sandbox and one production device receive a private terminal outcome.

## Terminal outcomes

- `review_ready`: newly discovered, reviewable subscriptions exist; the alert carries only the count.
- `no_new_discoveries`: the batch completed without new review candidates.
- `reconnect_required`: a provider authorization failure prevented completion; the alert routes to Inbox Intelligence.

Live Activity progress reports checked-message and completed-inbox counts only at durable job boundaries. It deliberately omits a percentage when the provider cannot supply a trustworthy total, and it ends with the same private terminal outcome. An installation with the completed Live Activity does not receive a duplicate ordinary final alert; other enabled devices still do.
