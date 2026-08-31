## Context

The current managed scan task fetches up to 30 historical pages and submits all page analyses through
one Trigger.dev batch. Each page task creates `new Pool()` and `PostgresSaver.fromConnString()`;
the latter creates a separate `pg.Pool` and is never closed. The development worker therefore retains
database sessions after pages finish. Against the Supabase session pool's 15-client limit, the live
scan completed eight pages, began failing further pages with `EMAXCONNSESSION`, and left the execution
ledger split between failed, running, pending, and retryable records.

The current ledger records an execution, but it does not own dispatch. Trigger's batch and native retry
are expected to do that. A reaper can turn an expired `running` record into `retryable`, but no durable
component turns that record back into a new task. Additionally, a Trigger concurrency key creates a
separate queue per key, so it cannot enforce an application-wide capacity budget across users.

The system must support many concurrent users while honoring finite database, provider, and model
capacity. "Concurrent" means each user gets a durable, fairly scheduled work stream; it does not mean
opening a dedicated database session for every possible page.

## Goals / Non-Goals

**Goals:**

- Prevent any page task from leaking a database connection or exceeding an explicit connection budget.
- Make the durable execution ledger the source of truth for dispatch, retry, cancellation, and terminal
  status, independent of a specific Trigger.dev run's survival.
- Start work fairly across users and keep global/provider concurrency within configured safe limits.
- Ensure a cancelled or unrecoverable run becomes terminal, preserving candidates completed before that
  outcome.
- Give the app truthful page-aware progress while fetched pages are waiting for analysis.

**Non-Goals:**

- Removing Trigger.dev or running agent work in the iOS app.
- Parallelizing provider page fetching; continuation cursors remain strictly sequential.
- Increasing the historical 3,000-message cap or changing discovery/model behavior.
- Guaranteeing every one of 100 simultaneous pages executes literally at once; capacity is deliberately
  finite and must be provisioned, but every user receives fair forward progress.

## Decisions

### D1 — One bounded, explicitly closed database pool per managed task

Every `analyze-inbox-page` invocation creates one `pg.Pool` with a small explicit maximum (initially
one connection), injects that pool into `PostgresSaver`, and closes the checkpointer/pool in `finally`.
The normal page path does not call checkpointer setup on every execution; initialization is serialized
as deployment/bootstrap work. Managed task traffic uses a dedicated `MANAGED_DATABASE_URL` configured
for Supabase transaction pooling; development local Postgres remains supported.

*Why:* this removes the existing hidden second pool and makes connection consumption measurable and
bounded. Transaction pooling is designed for short-lived, horizontally scaled workers, while the
session pool assigns one backend connection to each client for its lifetime.

*Alternatives considered:*
- Keep session pooling and lower Trigger concurrency — rejected because the leaked checkpointer pool
  eventually exhausts any finite session limit.
- Reuse one process-global pool — rejected as the primary guarantee because serverless task containers
  have independent lifetimes and can scale horizontally; each invocation still needs a hard bound and
  cleanup.
- Move all graph state out of Postgres — deferred; it is a larger data-model rewrite and does not fix
  the leaked connection lifecycle.

### D2 — Database-led dispatcher, not batch/native-retry-led dispatch

The mailbox-fetch orchestrator continues to create page jobs sequentially, but only admits durable
`page_analysis` executions. It does not batch-trigger all page analyses. A scheduled managed dispatcher
atomically reserves ready executions from the ledger and then triggers individual page tasks. A task
receives an execution ID and unique dispatch-attempt token; it may run only if that reservation is
still valid.

The dispatcher selects only `queued` or due `retryable` work whose run is not cancelling, applies a
global active-work budget and per-provider budget, and selects an initial fair set with no user taking
more than the configured per-user dispatch allowance in a round. It records the Trigger runtime ID
after successful submission. A failed submission leaves a lease that the reaper can safely return to
ready work.

*Why:* the ledger survives a task crash, local worker restart, or Trigger retry failure. Atomic
reservation with `FOR UPDATE SKIP LOCKED` makes dispatcher executions safe to overlap, and fairness is
enforced before work reaches Trigger.dev.

*Alternatives considered:*
- Depend solely on `batchTriggerAndWait` plus concurrency keys — rejected because a key scopes a copy of
  a queue, not a shared global capacity, and it leaves retry redelivery outside the ledger.
- Use a permanently running polling worker — rejected for production because availability would depend
  on a developer process and recovery would remain process-local.

### D3 — One retry authority and terminal failure semantics

Page tasks persist their own success or retryable failure in the ledger. They do not additionally rely
on native Trigger task retries for the same delivery; the dispatcher is the single retry authority.
The reaper returns expired reservations/running work to retryable state until the bounded attempt limit.
On the final attempt it marks the linked page job failed, records a safe error, and invokes the existing
idempotent run finalizer. The dispatcher subsequently submits the next eligible work without operator
action.

*Why:* dual retry mechanisms create duplicate launches and inconsistent attempt counts. A single
durable retry authority makes a stopped local runner and an abandoned Trigger execution recoverable.

### D4 — Capacity is explicit in both the dispatcher and runtime

The database reservation function enforces the active global, per-user, and per-provider budgets.
`analyze-inbox-page` uses one non-keyed custom Trigger queue with a concurrency limit no larger than the
global budget. Development starts with a conservative global limit of four and per-user limit of one;
production values are configured separately only after measuring connection, provider, and model
headroom. The Trigger environment limit is configured at least as high as the application queue limit.

*Why:* a database-level admission gate is the only shared view across all per-user queues. Keeping the
runtime queue bound too provides defense in depth if dispatch is invoked more often than expected.

### D5 — Status and cancellation follow the durable ledger

The status endpoint derives `queued`, `analyzing`, and `retrying` counts from execution/page records
and exposes the fetched message count separately from analyzed pages. The Inbox presents a Stop action
for a cancellable run. Stopping persists `cancel_requested_at`, prevents dispatcher reservation, marks
unstarted reservations cancelled, and causes live tasks to exit before surfacing results. The run becomes
`cancelled` once active pages settle; hard failure becomes `failed`, never an indefinitely running scan.

*Why:* a 3,000-message scan has completed fetching but may still be analyzing. The UI must describe that
truth instead of making it appear stopped or finished.

## Risks / Trade-offs

- [Transaction pooling does not support session-specific Postgres behavior] → Validate LangGraph's
  node-postgres queries against the transaction pooler in development; do not use prepared or session
  state in managed page code.
- [A small global budget increases queue time under a burst] → Fair selection starts one stream for many
  users before granting second slots; use telemetry to increase capacity safely instead of allowing
  connection failures.
- [Dispatcher succeeds in reserving but crashes before triggering] → The lease expires, the reaper
  returns it to retryable work, and the next dispatcher run redelivers it with a new attempt token.
- [A task completes as its lease is reaped] → Reservation/state updates are conditional and terminal
  transitions plus run finalization are idempotent.
- [A database migration changes active behavior] → Deploy migration first with the dispatcher disabled,
  verify capacity metrics and a controlled scan, then enable dispatcher; rollback pauses dispatch while
  preserving the ledger for recovery.

## Migration Plan

1. Add the ledger reservation, dispatch-attempt, fair-capacity, recovery, and status SQL functions;
   deploy them with the dispatcher disabled.
2. Update worker connection ownership and task payloads; use a transaction-pooler `MANAGED_DATABASE_URL`;
   deploy the Trigger.dev worker with conservative development capacity.
3. Enable the scheduled dispatcher and disable batch fan-out/native duplicate retry paths.
4. Cancel or terminally fail the presently stuck run through the durable cancellation/finalization path;
   do not manually delete completed candidates.
5. Run controlled multi-page and multi-user scans, then tune capacity from connection and latency
   telemetry. Rollback pauses dispatch and returns leases to ready work; it does not discard rows.

## Open Questions

- What provider/model p95 supports safely increasing the initial global budget above four?
- Should a terminal page failure be shown as `failed` (initial behavior) or later gain a separate
  `partial` terminal status?
- Can the project use the Supabase transaction pooler immediately, or does the existing LangGraph
  checkpoint access reveal an unsupported session feature during the verification spike?
