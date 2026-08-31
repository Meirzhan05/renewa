## 1. Connection lifecycle and runtime configuration

- [x] 1.1 Add a dedicated managed-task database configuration that accepts local Postgres in development
      and requires/document transaction-pooler configuration for deployed Supabase task traffic.
- [x] 1.2 Replace `PostgresSaver.fromConnString()` in managed page analysis with a checkpointer that
      shares one explicitly bounded `pg.Pool`; close the checkpointer/pool on every terminal path.
- [x] 1.3 Move LangGraph checkpoint schema setup out of the normal per-page path and make bootstrap
      initialization safe to run repeatedly.
- [x] 1.4 Add tests that assert successful, failed, and cancelled page executions release all owned
      database resources.

## 2. Durable admission, reservation, and recovery

- [x] 2.1 Add an additive migration for dispatch-attempt identity, reservation lease metadata, and
      indexes required to select ready page executions efficiently.
- [x] 2.2 Implement an owner-safe SQL function that fairly reserves dispatchable work with row locking,
      global/provider/per-user active-work budgets, and cancellation exclusion.
- [x] 2.3 Implement SQL functions to attach a Trigger runtime ID to a valid reservation, return an
      unsubmitted/expired reservation to retryable state, and make final-attempt failure finalize its
      scan run idempotently.
- [x] 2.4 Update the existing reaper to reclaim both abandoned dispatch reservations and running leases,
      preserving bounded attempts and terminal finalization semantics.
- [x] 2.5 Add migration-level assertions for overlapping dispatch claims, fair multi-user selection,
      cancellation exclusion, expiry recovery, and exhausted-attempt failure.

## 3. Managed dispatcher and page task contract

- [x] 3.1 Change page-analysis payloads and edge context claims to use an execution ID plus a unique
      dispatch-attempt token; reject stale, cancelled, or already-terminal delivery attempts.
- [x] 3.2 Replace full-run `batchTriggerAndWait` page fan-out with sequential fetch/admission followed
      by durable dispatcher-owned individual page triggering.
- [x] 3.3 Add a scheduled Trigger.dev dispatcher task that reserves a small fair batch, submits it,
      records the runtime IDs, and leaves failed submissions recoverable.
- [x] 3.4 Make the execution ledger the sole retry authority: persist retryable page failures, remove
      duplicate native retry behavior, and allow dispatcher redelivery after `available_at`.
- [x] 3.5 Configure non-keyed shared page and fetch queues with conservative development limits; enforce
      global, provider, and per-user budgets in the dispatcher rather than relying on concurrency-key
      copies of a queue.
- [x] 3.6 Add worker tests for stale-token rejection, redelivery after dispatcher/runtime interruption,
      capacity limits, and one-user-per-round fairness.

## 4. Truthful status and cancellation experience

- [x] 4.1 Update the scan status query/response to report fetched messages separately from queued,
      analyzing, retrying, failed, and cancelled page execution counts.
- [x] 4.2 Update the iOS Inbox scan presentation to explain the post-fetch analysis state, display a
      durable retry state, and remove any completion inference based on a local worker.
- [x] 4.3 Ensure the Stop action is visible for every cancellable Inbox scan and persists cancellation
      before it changes UI state; cancel unstarted work and safely stop in-flight work at its boundary.
- [x] 4.4 Add tests for fetched-but-analyzing, retrying, cancelled, and terminally failed status mapping.

## 5. End-to-end verification and rollout

- [x] 5.1 Run worker typecheck/tests and the simulator build; validate the OpenSpec change strictly.
- [x] 5.2 Apply the migration to the development Supabase project, configure the transaction-pooler
      managed database URL and conservative Trigger.dev development concurrency, then deploy the worker.
- [ ] 5.3 Run a controlled multi-page scan and confirm database connections remain bounded, one user
      cannot monopolize capacity, retries are re-dispatched, and a run finalizes exactly once.
- [ ] 5.4 Run two or more concurrent user scans and confirm each begins progress without a session-pool
      exhaustion error or duplicate candidate.
- [x] 5.5 Verify Stop during queued and active analysis, then resolve the current stuck development run
      through the supported cancellation/finalization path without deleting completed discoveries.
- [x] 5.6 Document development versus production worker startup, Trigger queue limits, transaction-pooler
      configuration, monitoring signals, and safe capacity-tuning/rollback steps.
