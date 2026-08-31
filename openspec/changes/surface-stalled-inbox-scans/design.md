## Context

The managed inbox scan path is: app → edge `email-scan` (`action:"start"`) → `startScan` inserts an
`email_scan_jobs` row (the page *window*) → `scheduleUserJobs` → `processManagedUserJobs` →
`triggerManagedInboxTask("scan-inbox-run", …)` enqueues a run in the trigger.dev task runtime → the
run task fetches pages (`managed_page_context`), creates `inbox_agent_executions`, `analyze-inbox-page`
analyzes them, and proposals are bridged into `subscription_candidates`.

Observed failure (2026-08-31): the edge dispatched `scan-inbox-run` successfully, but the run sat in
the queue with `version: null` (no connected/deployed worker in the edge key's environment) and hit
its 10-minute TTL → **EXPIRED**, never executing. Result: `email_scan_run` stuck `running`, zero
executions, zero candidates, and the app — which only writes `emailScanStatus` on a successful,
progressing poll (`AppStore.pollEmailScan`) — showed 0 forever with no error.

Two code facts make this invisible:
- `scheduleUserJobs` (`email-scan/index.ts:491-503`) runs the dispatch fire-and-forget inside
  `.catch((e) => console.error(...))`; the app still gets `202 {status:"queued"}`. In managed mode,
  status polls also skip re-dispatch (`:184`), so a single failed/expired dispatch never recovers.
- `recover_expired_inbox_agent_executions()` keys off `inbox_agent_executions`. When a run EXPIRES
  before executing, **no execution row exists**, so the reaper has nothing to act on.

Constraints: edge is Deno on Supabase; recovery must be driftless and idempotent; pg_cron is already
installed and runs the existing reaper every minute; the client contract must not change.

## Goals / Non-Goals

**Goals:**
- Every un-executable scan reaches a terminal `failed` state with a user-facing reason within a
  bounded, configurable window.
- Dispatch failures are recorded on the run, not swallowed.
- Terminal task-runtime states (EXPIRED/failed) reconcile to a scan failure idempotently.
- Orphaned worker jobs stop skewing liveness and get finalized.

**Non-Goals:**
- Improving what the two-tier funnel proposes on a real inbox (separate work).
- Changing the discovery reconcile/lifecycle math.
- Changing the app/edge request/response contract (statuses already exist).
- Guaranteeing a worker is *running* — that's the ops/env contract, not something code can force.

## Decisions

**D1 — Backstop the reaper on the run, not the execution.** Add a rule to the recovery function
(extend `recover_expired_inbox_agent_executions()` or add a sibling scheduled by the same pg_cron):
an `email_scan_run` that has been `running` longer than a dispatch-grace window **with zero linked
`inbox_agent_executions`** is failed with reason "Scan worker is unavailable" and finalized via
`finalize_email_scan_run_if_drained`. This closes the exact "expired before execution" gap.
*Alternative considered:* have the edge poll trigger.dev run status on each status call — rejected:
couples the edge to the runtime API on the hot polling path and adds latency/failure surface; the
DB-side reaper already exists and runs every minute.

**D2 — Grace window ≥ dispatched TTL.** The run TTL is `10m`; the backstop grace must be at least
that plus a small margin (default ~12m) so a slow-but-alive worker isn't failed prematurely. Make it
an env-configurable value (mirrors `SCAN_COMPLETION_TIMEOUT_MS`).

**D3 — Record dispatch outcome in the edge.** `scheduleUserJobs` stops swallowing: on a managed
dispatch error, write `email_scan_run.status='failed'` with a sanitized reason before returning.
Keep it best-effort and non-throwing to the client (still return a valid status body), but the body
now reflects `failed`. *Alternative:* make `start` await dispatch and 5xx on failure — rejected:
`start` is meant to return fast and a partial multi-connection dispatch shouldn't fail the whole
request; recording per-run is more precise.

**D4 — Idempotent resolution.** All transitions guard on non-terminal current state (`running` only),
matching the existing write-through failure loop (`:1210-1226`). A run already `failed`/`completed`
is never touched, so the reaper, the edge write-through, and any future callback converge safely.

**D5 — Orphan cleanup as a bounded migration step.** A one-off, reversible statement fails/closes
`scan_jobs` rows in a non-terminal state whose `scan_run_id` has no `email_scan_runs` row, and status
liveness excludes jobs with no live parent. Keep it a explicit, logged migration, not a recurring
delete.

**D6 — Governance: reconcile the deployed branch to `main`.** The live agent is `codex/unify-tab-transition`
(`44f91a4`, idempotency `v2`); `main` is `v1`. Merge/rebase the managed-dispatch changes onto `main`
and document that the edge `TRIGGER_SECRET_KEY` environment MUST match a live worker deploy in that
environment. This is a task, not a spec requirement, but it is a precondition for the fix to matter.

## Risks / Trade-offs

- **Premature failure of a slow, healthy run** → Mitigated by D2 (grace ≥ TTL + margin) and by D1
  requiring *zero* executions (a run that started analyzing has an execution row and is out of scope).
- **Masking the real cause (no worker) as a generic error** → Reason string names worker
  unavailability specifically; the env-contract doc (D6) tells operators what to check.
- **Double-finalize races between reaper, edge write-through, and callback** → D4 idempotency guards.
- **Orphan cleanup removing rows a delayed worker still wants** → D5 only touches jobs whose parent
  run is *gone*; a live run's jobs are never in scope.

## Migration Plan

1. Migration: extend the recovery function with the D1 run-level backstop + D5 orphan cleanup;
   reuse the existing every-minute pg_cron schedule (no new cron needed).
2. Edge: implement D3 (record dispatch outcome) and the D1 classification in `scanStatus` so a poll
   during the gap already reports `failed`.
3. Reconcile the managed-dispatch branch onto `main` (D6); align `taskVersion`.
4. Deploy edge; apply migration; ensure a worker is live in the edge key's environment (or move the
   edge to a prod key + `trigger deploy`).
5. Verify (see tasks): start a scan with no worker → run fails within the grace window with the
   worker-unavailable reason; start a scan with a worker → candidates land.

**Rollback:** the migration is additive (new recovery branch + a one-off cleanup); dropping the new
recovery branch reverts to prior behavior without data loss.

## Open Questions

- Should a trigger.dev **run-completion webhook** be wired so EXPIRED/failed resolves immediately
  instead of waiting for the reaper tick? (Faster UX; more surface area. Defer unless the 1-minute
  reaper latency is judged too slow.)
- Long-term, should the edge move fully off the dev key onto a prod deploy, and should `main` become
  the single deploy source to end the branch skew?
