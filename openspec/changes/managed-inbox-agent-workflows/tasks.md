## 1. Managed runtime foundation

- [x] 1.1 Add the Trigger.dev task-runtime package, project configuration, environment validation,
      and a narrow local adapter that keeps runtime calls out of the scan API and domain pipeline.
- [x] 1.2 Define versioned, identifier-only contracts for `scanInboxRun` and
      `analyzeInboxPage`, with deterministic idempotency keys based on run, page, and operation.
- [x] 1.3 Change local scripts so `npm start` cannot accidentally consume production-like agent
      work; reserve an explicit development-only worker/task command for intentional local runs.

## 2. Durable execution and cancellation state

- [x] 2.1 Add an additive Supabase migration for managed agent-execution records or equivalent
      queue metadata: runtime task ID, idempotency key, attempt, state, lease, heartbeat,
      retry-at, terminal error, and correlation fields.
- [ ] 2.2 Add owner-scoped scan cancellation state and a safe cancelled terminal outcome while
      preserving existing completed, failed, and partial semantics.
- [ ] 2.3 Implement atomic database routines for task admission/claim, heartbeat renewal, terminal
      acknowledgement, expired-lease recovery, and idempotent completion coordination.
- [ ] 2.4 Add RLS/grants and migration tests proving users cannot read or mutate other users'
      execution state and task metadata cannot bypass the review gate.

## 3. Secure workflow execution

- [ ] 3.1 Implement the managed scan orchestrator that owns one connection/run, advances
      pagination, and schedules page analysis without requiring iOS follow-up requests.
- [ ] 3.2 Move the existing agent page pipeline into the managed page-analysis task, retaining
      validated evidence, candidate reconciliation, and the shared run finalizer.
- [ ] 3.3 Replace token-bearing worker-job payloads with server-side, just-in-time credential
      retrieval; ensure task payloads, database execution records, and logs contain only opaque
      identifiers and redacted diagnostics.
- [ ] 3.4 Make task retries and duplicate delivery idempotent for candidate, event, outcome, and
      terminal scan writes; discard late results from cancelled scans.
- [ ] 3.5 Implement bounded exponential retry, heartbeat/lease expiry recovery, and permanent
      error handling that retains successful earlier candidates and reports a safe outcome.

## 4. Fair capacity control

- [ ] 4.1 Add deployment-configured global, Gmail, Microsoft, and per-user execution limits with
      startup validation and safe defaults.
- [ ] 4.2 Implement fair admission across eligible users, enforcing one active scan and one active
      page analysis per user by default while respecting provider and global capacity.
- [ ] 4.3 Add operator-visible capacity and queue-latency metrics without exposing task IDs or
      internal queue depth in the client API.

## 5. API and Inbox experience

- [ ] 5.1 Update `email-scan` to create/admit managed workflows, mirror runtime transitions into
      the Supabase scan ledger, and stop depending on the polling Node worker.
- [ ] 5.2 Add an authenticated owner cancellation action and status mapping for queued, running,
      capacity-waiting, cancelled, completed, partial, and failed scan outcomes.
- [ ] 5.3 Update the iOS Inbox to present user-safe waiting/running/cancelled states, continue
      foreground refresh while active, and preserve review candidates that arrive before terminal
      completion.

## 6. Verification and staged release

- [ ] 6.1 Add unit tests for idempotency keys, admission fairness, configured concurrency,
      cancellation boundaries, lease expiry, retries, and duplicate task delivery.
- [ ] 6.2 Add database and Edge Function integration tests covering no-local-worker execution,
      token-free task payloads, run finalization, safe terminal failures, and owner scoping.
- [ ] 6.3 Add XCTest coverage for capacity-waiting, cancellation, foreground resumption, and
      terminal scan presentation.
- [ ] 6.4 Run a synthetic multi-user load test that starts at least 100 scans, verifies fair
      concurrent progress, validates provider/model rate limits, and measures the defined
      completion-time target and cost.
- [ ] 6.5 Provision the managed-runtime project, production secrets, concurrency controls,
      dashboards, alerts, and data-retention settings; deploy it disabled and complete privacy/
      security review before production traffic.
- [ ] 6.6 Roll out behind a server-side flag, validate internal and staged-user scans, drain legacy
      worker jobs, retire the production `npm start` dependency, and document rollback and
      operating procedures.
