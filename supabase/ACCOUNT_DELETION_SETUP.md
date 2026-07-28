# Account Deletion Setup

The iOS Delete account action calls the authenticated `delete-account` Edge Function. The Function determines the user from the bearer token and uses a server-only Supabase service-role key to permanently delete that user. The app never sends a target user ID.

Deploy it after confirming the Supabase project has a server key available to Edge Functions:

```sh
supabase functions deploy delete-account
supabase secrets set SUPABASE_SERVICE_ROLE_KEY=...
```

If the project uses the newer secret key naming, set `SUPABASE_SECRET_KEY` instead. Do not place either value in `Config.local.xcconfig` or the iOS app.

Before release, use a dedicated test account with a profile, subscriptions, a connected mailbox, scan history, billing events, snapshots, and Insight reports. Confirm that entering `DELETE` removes the Auth user and all associated records, then verify a failed request leaves the account intact. This action is permanent.
