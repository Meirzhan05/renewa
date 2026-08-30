## Why

A historical scan analyzes its mailbox pages strictly one at a time: the `scan-inbox-run`
orchestrator `triggerAndWait`s each page's analysis before fetching the next. Measured, that is ~3
min/page — an 18-page scan took ~52 minutes. The managed design (`managed-inbox-agent-workflows` D3)
already provisions per-user / provider / global concurrency budgets and explicitly calls them tunable
deployment values, but two things pin per-user throughput at 1: the budget defaults to one active page
analysis per user, and — more fundamentally — the sequential parent never dispatches more than one
analysis at a time regardless of the budget. This change lets a single run analyze pages in parallel,
bounded by those existing budgets.

## What Changes

- The orchestrator SHALL dispatch page analyses **concurrently** within a run instead of awaiting each
  before starting the next. Page **fetching stays sequential** (the provider continuation cursor is
  inherently ordered); only the expensive analysis step fans out.
- Per-user analysis concurrency SHALL be raised from 1 to a configurable **N** (default **4**) via the
  existing `INBOX_AGENT_PER_USER_CONCURRENCY` budget, and analyses SHALL carry a per-user concurrency
  key so the budget is actually enforced at the queue.
- The global and provider ceilings SHALL continue to bound total load (unchanged), so per-user
  parallelism cannot exceed measured provider/model capacity.
- Run completion, idempotency, retry, and cancellation semantics SHALL be **unchanged**: the drain
  finalizer still completes a run only when all pages are terminal; deterministic per-page idempotency
  keys keep parallel dispatch safe; cancellation still stops further analysis.
- No change to the `email-scan` request/response contract; no iOS change.

## Capabilities

### New Capabilities
- `managed-scan-throughput`: Defines bounded intra-run parallelism for page analysis — concurrent
  analysis within a run, sequential fetch, and correctness under the existing concurrency budgets.

### Modified Capabilities
<!-- none: openspec/specs is empty; managed-inbox-agent-workflows (which owns the concurrency-budget
     design) is still an in-progress change, so this is captured as a new capability that builds on it -->

## Impact

- **Worker:** `worker/src/trigger/scan-inbox-run.ts` (orchestrator: fetch sequentially, then fan
  page analyses out with a per-user concurrency key), `worker/src/managed/config.ts`
  (`INBOX_AGENT_PER_USER_CONCURRENCY` default 1 → 4). Redeploy the trigger.dev worker.
- **Behavior:** a multi-page scan finishes ~N× faster (bounded by budgets); "messages checked" (now
  cumulative from the counts fix) climbs quickly during fetch, "changes detected" climbs as analyses
  land.
- **No DB migration**, no edge change, no client change.
- **Depends on:** the managed concurrency-budget infrastructure from `managed-inbox-agent-workflows`
  and the cumulative counts from `fix-managed-scan-page-counts`.
- **Out of scope:** bounding scan size / lookback, parallelizing fetch, and any change to the budget
  infrastructure itself.
