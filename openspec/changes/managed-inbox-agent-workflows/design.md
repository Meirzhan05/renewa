## Context

Inbox scans currently use two database-backed queues. The Supabase `email-scan` Function fetches a
mailbox page and enqueues a `scan_jobs` row; a locally launched Node process polls that row every
few seconds, runs the agent, and writes review candidates. This process has no deployed owner, job
lease, heartbeat, fair admission, or autoscaling policy. A process interruption after claiming a
job leaves its `running` state ambiguous.

The existing paginated-scan completion change remains necessary: candidates can arrive page by
page, but only the final database coordinator declares a scan terminal. This change replaces the
execution mechanism behind that lifecycle, not the review-first product model.

## Goals / Non-Goals

**Goals:**

- Execute Inbox agents from a deployed managed runtime rather than from a developer machine.
- Let many users make concurrent progress while bounding work to provider, model, and budget
  capacity.
- Make task retries, crashes, cancellations, and duplicate delivery safe and observable.
- Keep Supabase run/candidate records the source of truth for owner-scoped iOS status.
- Keep mailbox credentials server-side and out of generic task payloads.

**Non-Goals:**

- Promise that unlimited full-mailbox scans finish immediately; capacity is an explicit operating
  limit and depends on observed model/provider performance.
- Change the review-first candidate gate, extraction semantics, provider pagination bounds, or
  expose task platform data to iOS.
- Build a general-purpose workflow engine or migrate unrelated background work.

## Decisions

### D1: Adopt a managed workflow runtime for production agent execution

Use Trigger.dev Cloud as the initial production runtime for long-running Inbox workflow and page
analysis tasks. It provides managed task execution, retry control, queues, concurrency settings,
and operational visibility. Keep task inputs and persistence behind a thin local adapter so a
future self-hosted Trigger.dev or different runtime does not require changing the scan API or iOS
client.

*Alternative — deploy the existing infinite polling loop to one hosted container:* rejected. It
removes the laptop dependency but leaves bespoke leases, fair scheduling, autoscaling, retries, and
task observability to operate. *Alternative — use Supabase Queues plus an autoscaled worker:*
viable later, but still requires a separately operated consumer and scheduling/scaling mechanism.
*Alternative — run the agent in an Edge Function:* rejected because page analysis is long-running
and needs durable retries and controlled concurrency.

### D2: Split each scan into an orchestrator and idempotent page-analysis tasks

`scanInboxRun` owns a single connection/run lifecycle. It fetches or schedules the next eligible
mailbox page and triggers an `analyzeInboxPage` task identified by `(scan_run_id, page_number)`.
The page task retrieves the page's server-side data, runs the existing agent pipeline, persists
facts and review candidates, and records a terminal outcome. The orchestrator schedules follow-up
pagination without blocking an execution slot while it waits for child work.

The database remains the authoritative task ledger. Managed-runtime task IDs, attempt number,
lease/heartbeat timestamps, and terminal metadata are mirrored to a new agent-execution record or
to extended queue metadata. The completion coordinator continues to lock and finalize
`email_scan_runs` only after all linked work is terminal.

*Alternative — one giant task per mailbox:* rejected. It prevents page-level retry/progress,
amplifies a single failure, and limits fair parallelism. *Alternative — keep every worker page in a
hand-rolled `scan_jobs` poll loop:* rejected by D1.

### D3: Use explicit fair concurrency budgets instead of one global FIFO worker

Configure concurrency at three layers:

1. a global agent-analysis ceiling set from measured provider/model capacity and cost budget;
2. provider-specific ceilings to protect Gmail and Microsoft APIs; and
3. one active full scan and one active page analysis per user by default.

The admission layer SHALL select eligible work fairly across users, not allow a large historical
scan from one user to monopolize the global pool. Values are deployment configuration, not source
constants, and are tuned from load tests and production telemetry. A product target such as a
normal-scan p95 completion time defines the required capacity; it is not inferred from an arbitrary
worker count.

*Alternative — unlimited parallel task starts:* rejected because it can exceed API/model limits and
produce unpredictable cost. *Alternative — strict global FIFO:* rejected because early large scans
can starve later users.

### D4: Make delivery at-least-once safe through database idempotency and recovery

Every managed task uses a deterministic idempotency key based on scan run, page, and operation.
Before external/provider or model work, it atomically claims the matching durable execution record.
Each active task writes a heartbeat before its lease expires. A scheduled reaper returns expired
work to an eligible retry state, subject to a bounded retry count and exponential backoff. Terminal
writes are idempotent, so a retry cannot duplicate a candidate, event, or scan completion.

A cancellation request persists on the scan run. Orchestrators stop scheduling future pages, and
page tasks observe cancellation at safe boundaries; an already executing model call is allowed to
finish or time out but its result is ignored when the run is cancelled.

*Alternative — trust the managed runtime alone for exactly-once semantics:* rejected. A task can
complete its external/model side effect while its final database acknowledgement is interrupted.

### D5: Keep credentials off queue/task payloads and surface only product state to iOS

Managed task payloads contain opaque run/job/page IDs only. A task uses privileged server-side
credential access to decrypt a provider token only when needed, keeps it in memory for that
operation, and does not log it or persist it to agent job payloads. The iOS status endpoint reads
the Supabase run ledger and returns user-safe states (`queued`, `running`, `completed`, `partial`,
`failed`, `cancelled`) plus review counts; it does not expose platform task IDs, leases, raw email,
or queue depth.

*Alternative — send provider tokens in the task payload or `scan_jobs` row:* rejected because
durable task payloads and worker tables are inappropriate credential stores.

## Risks / Trade-offs

- **[Managed runtime adds vendor dependency and cost]** → Keep a narrow task-runtime adapter,
  document environment configuration, and retain the database ledger as the product source of
  truth.
- **[Burst demand exceeds current concurrency]** → Use admission controls, clear queued progress,
  budget alerts, and capacity load tests before launch.
- **[Provider/model throttling creates retries]** → Apply provider-scoped limits, exponential
  backoff, bounded attempts, and terminal partial/failure reporting.
- **[Duplicate task delivery]** → Require deterministic idempotency keys, database claim records,
  and idempotent candidate/finalizer writes.
- **[Cancelled scan returns a late result]** → Check cancellation before persistence and make
  candidate writes reject cancelled runs.
- **[Migration interrupts active scans]** → Introduce the managed path behind a rollout flag, let
  existing worker jobs drain, and retain compatibility until the new path is verified.

## Migration Plan

1. Define the runtime adapter, task contracts, execution ledger, lease/retry/cancellation schema,
   and privileged credential retrieval path.
2. Deploy managed tasks and infrastructure with execution disabled; exercise them using synthetic
   runs and load tests.
3. Enable the managed path for internal users, observe throughput, retries, provider rate limits,
   cost, and p95 completion time, then tune configured limits.
4. Gradually route production scans to the managed path while retaining the completion coordinator
   and read-side status aggregation.
5. After all legacy jobs drain and the new path is stable, remove the local-worker requirement and
   retire token-bearing `scan_jobs` payload fields.

Rollback: stop admitting new managed tasks, leave completed/candidate data intact, and route new
scans to the prior compatible path while failed/in-flight work is reconciled from the database
ledger. No user-visible scan is marked complete solely because of a runtime transition.

## Open Questions

- What normal-scan p95 completion-time target and monthly model budget should determine the initial
  global concurrency ceiling?
- Which Trigger.dev plan, region, retention setting, and data-processing terms meet the product's
  privacy and operational requirements?
- Does the selected runtime support the required per-user keyed concurrency directly, or should the
  Supabase admission routine enforce it before task triggering?
- Which UI wording best distinguishes a normal capacity wait from a retryable failure without
  exposing internal queue details?
