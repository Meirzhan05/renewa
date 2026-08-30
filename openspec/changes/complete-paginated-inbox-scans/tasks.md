## 1. Durable scan completion coordination

- [x] 1.1 Add an idempotent Supabase migration that makes the worker queue schema and run-link
      columns available after `supabase db reset`, without deleting existing queue data.
- [x] 1.2 Add a locked, idempotent `finalize_email_scan_run_if_drained` database routine that
      checks all linked edge and worker jobs and writes the correct completed or failed run state
      only after all are terminal.
- [x] 1.3 Cover the routine with local database assertions for active work, successful multi-page
      completion, failed page completion, repeated calls, and concurrent Edge/worker invocation.

## 2. Worker page lifecycle

- [x] 2.1 Refactor `bridgeProposalsToCandidates` so it persists page evidence and candidates without
      finalizing `email_scan_runs`.
- [x] 2.2 Invoke the completion coordinator after the persistent worker marks a scan job completed
      or failed, preserving existing proposal/outcome persistence.
- [x] 2.3 Extend worker tests for a first completed page with later pages pending, final successful
      page completion, and candidate retention when a later page fails.

## 3. Edge orchestration and status aggregation

- [x] 3.1 Invoke the completion coordinator after each edge mailbox-page job reaches a terminal
      state, including its final retry failure path.
- [x] 3.2 Rework `email-scan` status derivation to group every `email_scan_jobs` and `scan_jobs`
      row by run, keeping the batch active while any linked job remains active.
- [x] 3.3 Preserve worker-down timeout behavior and correctly report a failed run or partial batch
      once all linked work is terminal.
- [x] 3.4 Add Deno coverage for multiple worker jobs per run, stale early-completed runs with active
      pages, mixed connection outcomes, and terminal finalization after the last page.

## 4. Inbox long-scan synchronization

- [x] 4.1 Replace the fixed 120-iteration scan poll with cancellation-aware, paced polling that
      continues until the scan reaches a terminal status.
- [x] 4.2 Resume an active scan's polling when Inbox appears or the app returns to the foreground,
      and apply bounded retry backoff for transient status failures.
- [ ] 4.3 Add XCTest coverage for scans longer than four minutes, foreground resumption, terminal
      cancellation, and retained active presentation during a refresh failure.

## 5. Verification and release

- [x] 5.1 Run worker typecheck and tests, Deno checks/tests for the Edge Function, the iOS test
      target, and a signing-free iOS build.
- [ ] 5.2 Reset a local database, apply the worker queue migration path, and run an end-to-end
      multi-page scan to verify the run remains active after page one.
- [ ] 5.3 Apply the migration and deploy the updated `email-scan` Function and worker to the hosted
      project, then verify a 2+-page production-like scan remains active until the final worker job
      is terminal and surfaces its review results without reopening Inbox.
