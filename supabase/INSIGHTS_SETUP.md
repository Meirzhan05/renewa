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

AI reports are cached for 24 hours per unchanged fact set. Each non-empty report includes privacy-safe provenance: whether it was AI-generated or deterministic, whether this response reused a cache entry, the server generation time, and aggregate counts of the subscriptions, billing events, and snapshots considered. It never includes email text, message subjects, credentials, model prompts, provider errors, or secrets.

If AI generation is unavailable, the Function returns a deterministic subscription summary and the iOS charts remain available. The client labels that state as a **Basic subscription summary** and offers a forced retry without removing the visible result. A forced retry bypasses the matching cache lookup; normal app visits reuse a valid matching cache entry. The Function logs only categorized outcomes (`cache_hit`, `ai_generated`, `ai_fallback`, `validation_failed`, or `request_failed`) with aggregate evidence counts.

Deploy the Function before publishing a client that expects provenance fields. Older clients remain compatible because they use the existing report payload fields. Roll back by redeploying the prior Function or hiding its UI call; the history table and charts do not depend on AI output.
