## Context

One `email_scan_runs` row represents a connected inbox in a manually started batch. A historical
scan fetches a maximum of 100 messages per mailbox page and can enqueue up to 30 pages. Each page
produces one edge-side `email_scan_jobs` row and one persistent-worker `scan_jobs` row, all linked
to the same run.

The candidate bridge currently persists a page's discoveries and immediately sets that shared run
to `completed`. The first completed worker page therefore makes the status endpoint terminal while
later worker pages remain pending. The endpoint also maps one worker job per run, losing the state
of the other pages. On the client, `pollEmailScan` exits after 120 two-second iterations, so it
cannot observe a legitimate scan that runs longer than about four minutes.

## Goals / Non-Goals

**Goals:**

- Make the persisted run lifecycle and app-visible lifecycle represent all work in a paginated scan.
- Let page results enter the review queue promptly without implying that the entire scan finished.
- Ensure the Inbox remains synchronized with active long scans while it is visible or returns to the
  foreground.
- Preserve the existing authenticated `email-scan` response shape and human review gate.
- Make terminal completion/failure durable and race-safe for both the Edge Function and worker.

**Non-Goals:**

- Changing provider pagination limits, worker model prompts, candidate safety policy, or the
  semantics of an already terminal scan.
- Adding a real-time transport; adaptive polling is sufficient for this correction.
- Retrying or recovering a worker job that is actively stuck after it has been claimed.
- Exposing raw email data, job IDs, or internal queue details to the iOS client.

## Decisions

### D1: Separate page-result persistence from run finalization

`bridgeProposalsToCandidates` SHALL persist a page's evidence and review candidates but SHALL NOT
set `email_scan_runs.status` or `completed_at`. A scan run has many pages; only a completion
coordinator may set its terminal lifecycle.

*Alternative — keep the bridge completion and override it in status reads:* rejected. It leaves an
incorrect durable record, produces premature completion side effects, and reintroduces the race to
every new status consumer.

### D2: Use one database completion coordinator, invoked after every terminal queue transition

Add a guarded database routine, `finalize_email_scan_run_if_drained(run_id)`, backed by a Supabase
migration. It SHALL lock the target run, examine every linked `email_scan_jobs` and `scan_jobs` row,
and return without mutation while either queue has active work. When all rows are terminal, it SHALL
persist one final run outcome:

- no failed job → `completed` with `review_ready` when the run has pending candidates, otherwise
  `completed`;
- one or more failed jobs → `failed`, with a safe aggregate error message.

The Edge Function SHALL invoke this routine after it marks an edge page job terminal, and the worker
SHALL invoke it after it marks a worker job terminal (both successful and failed). Calling from both
transition points closes the race where a worker finishes the final page just before the Edge Function
marks that page's fetch job complete. The routine's lock and terminal-state guard make repeated calls
idempotent.

*Alternative — finalize only in the worker:* rejected because the final edge-page transition can
occur after the final worker transition. *Alternative — finalize only during status polling:* rejected
because a run would remain nonterminal when the app is not polling.

### D3: Derive status from all queue rows as a defense-in-depth invariant

The `email-scan` status path SHALL group all worker and edge job states by run; it SHALL NOT select
one arbitrary `scan_jobs` row through a `Map<scan_run_id, job>`. Any linked edge job in `queued` or
`running`, or worker job in `pending` or `running`, keeps the run and batch app-visible as active,
even if a stale persisted record says `completed`. Existing bounded timeout classification remains
for unclaimed/missing worker work; terminal job failures contribute a failed run and partial batch
when another connection succeeds.

This guard makes status truthful during rollouts and protects against legacy prematurely-completed
runs. It is not the primary finalization mechanism; D2 owns durable lifecycle writes.

*Alternative — trust only `email_scan_runs`:* rejected because that was precisely the premature-
completion failure mode. *Alternative — expose every queue row to iOS:* rejected because it expands
the API with internal operational detail that the UI does not need.

### D4: Keep foreground Inbox polling alive with a paced cadence

Replace the fixed 120-iteration poll loop with a task that continues until a terminal status,
cancellation, or sign-out. Use the current fast cadence for the first short window, then a slower
cadence to limit requests during model-intensive backfills. When Inbox appears or the app returns to
the foreground, reload the current scan status and resume the task if that status is active. A
transient status-fetch failure SHALL retry with bounded backoff and leave the current visible state
unchanged rather than incorrectly presenting completion.

*Alternative — poll every two seconds indefinitely:* rejected because a 30-page scan can run for a
long time and does not need high-frequency UI refreshes after its initial phase. *Alternative — rely
only on completion notifications:* rejected because notifications are optional and cannot guarantee
that an open Inbox refreshes its review queue.

### D5: Verify the shared database schema and deploy all participants together

The completion routine migration SHALL be applied to the same Supabase Postgres instance used by
both the Edge Function and persistent worker. The worker queue schema must also be present there;
local development setup SHALL apply the worker migrations before testing the flow. Deploy the
migration, Edge Function, and worker as one compatibility set, then validate a multi-page scan
against the hosted project.

## Risks / Trade-offs

- **[Finalizer race between Edge and worker]** → The routine serializes on the run row, rechecks all
  queues under that lock, and is idempotently called after every terminal transition.
- **[One failed page hides successful earlier candidates]** → Persist candidates immediately and
  expose them; report the overall connection as failed and the batch as partial if another inbox
  finishes.
- **[Long foreground polling increases backend traffic]** → Use a paced cadence and stop instantly
  on terminal state, cancellation, or sign-out.
- **[Hosted/local schema drift]** → Test against a fresh local reset after worker migrations and
  verify remote migration state before deployment.
- **[Older edge code persists an early completion]** → D3 keeps the UI active while queue work is
  present; D2 prevents new early-complete writes once all components are deployed.

## Migration Plan

1. Add and apply the database completion-coordinator migration; verify the worker queue migrations
   exist in the target database.
2. Deploy the worker and `email-scan` Function that invoke the coordinator and aggregate all queue
   rows.
3. Ship the iOS sustained-polling change.
4. Run a hosted multi-page scan and verify: the scan remains active after page one, candidates may
   appear while it runs, and the terminal state appears only after the last worker page finishes.
5. Roll back code by redeploying the prior worker/Function and client if necessary. The routine is
   additive and safe to leave in place; no user data needs restoration.

## Open Questions

- What paced cadence best balances responsiveness and cost after the initial scan window (proposed:
  two seconds initially, then ten to fifteen seconds)?
- Should a run with any worker-page failure persist `failed` (recommended) or an explicit per-run
  `partial` state? The current model only gives `partial` meaning at the multi-connection aggregate.
- Should the finalizer make the scan's checked-message count cumulative across pages as part of this
  change, or should that accuracy improvement be tracked separately?
