## Why

Managed Inbox scans can exhaust Supabase's small session-mode connection pool and then remain
`running` indefinitely. A historical scan fans out up to 30 page analyses; each analysis currently
creates an unbounded application pool plus a second LangGraph checkpointer pool that is not closed.
The live 3,000-message scan demonstrated the outcome: completed work leaked connections, subsequent
pages failed with `EMAXCONNSESSION`, and retryable work was never durably re-dispatched.

This must be corrected before further rollout. A production Inbox agent must make bounded, fair
progress for many simultaneous users without relying on a developer laptop or leaving a scan in a
misleading non-terminal state.

## What Changes

- Replace per-page, unbounded session-pool usage with one bounded, explicitly closed database
  connection lifecycle that is compatible with Supabase transaction pooling.
- Make the Inbox execution ledger authoritative for admission, dispatch, retry, cancellation, and
  terminal status; Trigger.dev is the task runtime, not the only record that work exists.
- Add a durable, scheduled dispatcher that selects a capacity-bounded and user-fair set of ready
  page analyses, invokes their managed tasks, and resumes reclaimed work automatically.
- Enforce explicit deployment concurrency budgets: per-user, global, and provider capacity must be
  active controls with safe development defaults, not unused configuration fields.
- Surface accurate queued, analyzing, retrying, stopped, completed, and failed state from the durable
  ledger; a scan must reach a terminal outcome once its work is cancelled or cannot be recovered.
- Preserve sequential mailbox-page fetch, idempotent page analysis, existing candidates, and the
  public `email-scan` API contract.

## Capabilities

### New Capabilities

- `managed-inbox-dispatch-reliability`: Bounded database usage and durable, fair dispatch/recovery for
  managed Inbox page analyses.
- `inbox-scan-execution-status`: Truthful, terminal scan lifecycle state derived from durable execution
  records.

### Modified Capabilities

<!-- None. Repository main specs are currently empty; related managed Inbox changes are still delta
     changes, so this proposal defines additive requirements that supersede their unsafe rollout plan. -->

## Impact

- **Worker:** managed task connection ownership, queue configuration, and Trigger.dev deployment
  settings in `worker/src/trigger/`, `worker/src/managed/`, `worker/src/config.ts`, documentation, and
  development scripts.
- **Database:** additive migration(s) for durable dispatcher claiming, recovery handoff, capacity/fair
  scheduling, and terminal finalization.
- **Edge Function:** authenticated dispatcher/retry admission only if required to invoke Trigger.dev;
  no iOS request-contract change.
- **iOS:** Inbox progress/status mapping and Stop affordance consume the durable lifecycle; no email
  credentials or agent work run on-device.
- **Operations:** use Supabase transaction-pooler credentials for task traffic, deploy a managed
  Trigger.dev worker for production, and configure development concurrency independently from
  production capacity.
