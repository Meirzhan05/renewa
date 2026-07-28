# Account Deletion Setup

The iOS Delete account action calls the authenticated `delete-account` Edge Function. The Function determines the user from the bearer token and uses Supabase's server-only secret-key environment to permanently delete that user. The app never sends a target user ID.

On hosted Supabase projects, the platform automatically provides `SUPABASE_SECRET_KEYS` to Edge Functions. Do not create or set a secret with a `SUPABASE_` name: that prefix is reserved, and no manual key configuration is required.

Deploy the Function:

```sh
supabase functions deploy delete-account
```

The Function prefers the modern hosted key maps and retains local and legacy fallbacks for development. Never place a Supabase secret key in `Config.local.xcconfig`, the iOS app, Git, or chat.

Before release, use a dedicated test account with a profile, subscriptions, a connected mailbox, scan history, billing events, snapshots, and Insight reports. Confirm that entering `DELETE` removes the Auth user and all associated records, then verify a failed request leaves the account intact. This action is permanent.
