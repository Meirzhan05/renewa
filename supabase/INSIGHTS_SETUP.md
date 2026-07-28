# AI Insights Setup

The `insights-refresh` Function uses the existing server-only `DEEPSEEK_API_KEY` and optional `DEEPSEEK_MODEL` secrets. Do not add either value to the iOS `Config.local.xcconfig` file.

Deploy the migration and Function together:

```sh
supabase db push
supabase functions deploy insights-refresh
supabase secrets set DEEPSEEK_API_KEY=... DEEPSEEK_MODEL=deepseek-v4-flash
```

`monthly_spend_snapshots` is updated whenever a subscription is created, changed, or deleted. To retain a point at the start of every month for users with no intervening mutations, enable the `pg_cron` extension in the Supabase Dashboard and schedule this database call for shortly after midnight UTC on the first day of each month:

```sql
select cron.schedule(
  'capture-renewa-monthly-spend',
  '5 0 1 * *',
  $$select public.capture_all_monthly_spend_snapshots();$$
);
```

AI reports are cached for 24 hours per unchanged fact set. If the AI provider is unavailable, the Function returns a deterministic subscription summary and the iOS charts remain available. Roll back by removing the `insights-refresh` deployment or hiding its UI call; the history table and charts do not depend on AI output.
