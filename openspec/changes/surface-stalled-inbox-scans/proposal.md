## Why

An inbox scan silently stalls at "0 discoveries, never updating" whenever the trigger.dev
worker cannot execute the run the edge dispatched. On 2026-08-31 a real scan's `scan-inbox-run`
sat in the queue with `version: null` and **EXPIRED** after its 10-minute TTL (no connected/deployed
worker to claim it). The edge dispatch itself *succeeded*, so nothing was logged; the
`email_scan_run` stayed `running` forever; the app only updates its state on a successful,
progressing poll — so the user saw 0 with no error and no way to tell the scan was dead.

This class of failure is currently invisible for two reasons: the edge **swallows** dispatch
outcomes (`scheduleUserJobs` runs fire-and-forget inside `.catch(console.error)`), and the
`recover-stuck-scan-analyses` reaper keys off `inbox_agent_executions` rows — which are **never
created** when a run expires before it executes. Nothing fails the run, so it never reaches a
terminal state.

## What Changes

- A managed scan that is dispatched but produces **no execution within a bounded grace window**
  SHALL be failed with a user-facing reason (e.g. "Scan worker is unavailable — try again shortly.").
  This is the backstop that covers the "expired before it ever executed" gap the current reaper misses.
- Trigger.dev **dispatch outcomes SHALL be recorded** on the scan run rather than swallowed. A
  dispatch error (missing key, task not in the deployed version, transport failure) SHALL fail the
  run with a user-facing message instead of returning a healthy-looking `queued`.
- A trigger.dev run reaching a terminal **EXPIRED/failed** state SHALL resolve to a scan failure —
  via callback where available, and via the reaper backstop otherwise.
- **No client contract change.** The app already renders a failed run; it will simply start receiving
  `failed` instead of an indefinite `running`.
- **Governance:** reconcile the live agent code onto `main`. The deployed agent runs from branch
  `codex/unify-tab-transition` (commit `44f91a4`, idempotency `v2`), while `main` is behind (`v1`),
  so production behavior and the main line diverge. Document the environment contract: the edge's
  `TRIGGER_SECRET_KEY` environment (currently a **dev** key) MUST correspond to a live worker in that
  same environment, or every scan expires.
- **Cleanup:** finalize orphaned `pending` `scan_jobs` whose parent `email_scan_run` no longer exists
  (49 such rows found), so liveness/queue signals aren't skewed by dead work.

## Capabilities

### New Capabilities
- `inbox-scan-failure-visibility`: Guarantees that any inbox scan which cannot be executed —
  dispatch failure, no connected/deployed worker, trigger.dev TTL expiry, or no execution ever
  created — reaches a terminal `failed` state carrying a user-facing reason within a bounded time,
  rather than reporting 0 discoveries indefinitely.

### Modified Capabilities
<!-- none: openspec/specs/ is empty. The managed dispatch + recovery behavior this builds on lives
     in the in-flight changes `managed-inbox-agent-workflows` and `recover-stuck-scan-analyses`;
     this change adds the failure-visibility guarantee on top of them rather than restating them. -->

## Impact

- **Edge** (`supabase/functions/email-scan/index.ts`): `scheduleUserJobs` must stop swallowing
  dispatch errors and record the outcome on the run; the status classifier must treat "dispatched,
  `running` past the dispatch-grace window, with zero `inbox_agent_executions`" as `failed` with the
  worker-unavailable message.
- **Migration**: extend `recover_expired_inbox_agent_executions()` (or add a sibling reaper) with a
  backstop that fails such runs and calls `finalize_email_scan_run_if_drained`; plus a one-off,
  reversible cleanup of orphaned `pending` `scan_jobs`.
- **Worker** (`worker/src/trigger/*`): optionally record an execution/heartbeat row at run claim so
  the reaper has a positive liveness signal; align `taskVersion` with the edge.
- **App**: none (already renders `failed`); verify the message surfaces in `EmailScanView`.
- **Ops/docs**: capture the edge-key-environment ↔ worker-deploy-environment contract; reconcile the
  live branch onto `main`.
- **Out of scope**: improving what the two-tier funnel proposes on a real inbox (tracked separately),
  and any change to the reconcile/lifecycle math for discoveries.
