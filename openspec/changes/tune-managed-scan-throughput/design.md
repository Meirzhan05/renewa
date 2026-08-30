## Context

`orchestrateManagedScan` (in `scan-inbox-run.ts`) runs a strict loop: fetch one page via the edge,
`analyzeInboxPageTask.triggerAndWait(...)`, then fetch the next. So exactly one page analysis is ever
in flight per run. The three-layer concurrency budget from `managed-inbox-agent-workflows` D3
(`managed/config.ts`: global / provider / per-user) exists, but per-user defaults to 1 and the
sequential parent would ignore a higher value anyway. Page **analysis** (the Tier-1+Tier-2 LLM funnel)
is the ~3 min/page cost; page **fetch** is cheap and must stay ordered because it walks the provider
continuation cursor.

trigger.dev already gives us the primitives this needs: deterministic per-page idempotency keys
(`pageAnalysisIdempotencyKey`), durable retries, cancellation observed at page boundaries, and a drain
finalizer that completes a run only when every page is terminal. Parallel dispatch is therefore safe;
the work is orchestration + a budget default.

## Goals / Non-Goals

**Goals:**
- Analyze a run's pages concurrently, bounded by the per-user budget (≈N× faster).
- Keep fetch sequential (cursor integrity) and all existing correctness (idempotency, retry,
  cancellation, drain completion, cross-user fairness).
- Make the parallelism a tuned deployment value, not a source constant.

**Non-Goals:**
- Parallelizing fetch, overlapping fetch with analysis (possible later — see D4 alternative).
- Bounding scan size / lookback (separate change).
- Changing the budget infrastructure or the global/provider ceilings.

## Decisions

### D1 — Fetch sequentially, then fan analyses out with `batchTriggerAndWait`
The orchestrator keeps the sequential fetch loop (each `processManagedConnection` returns the next
`pageId`), but instead of awaiting each analysis it **collects the page ids** and, once fetching is
done (or a cap is hit), dispatches them together via `analyzeInboxPageTask.batchTriggerAndWait(items)`.
*Why:* `batchTriggerAndWait` checkpoints the parent while it waits — so the run still **releases its
queue slot during analysis** (the fairness property the original per-page `triggerAndWait` provided) —
while the children run in parallel up to the per-user budget. Each item keeps its
`pageAnalysisIdempotencyKey`, so a redelivered batch cannot double-analyze a page.
*Alternative — keep `triggerAndWait` but not await it (fire-and-forget):* rejected; the parent would
exit before analyses finish, losing cancellation/error aggregation and the natural "hold the run until
done" signal (completion would rely solely on the finalizer).

### D2 — Enforce the per-user bound with a per-user concurrency key
Every analysis is triggered with `concurrencyKey = user:<userId>` and the pages queue's per-key limit
= the per-user budget. Raise the `INBOX_AGENT_PER_USER_CONCURRENCY` default **1 → 4**. Global and
provider ceilings are unchanged, so total concurrent analyses across all users stays within measured
provider/model capacity; a single big scan can use at most N slots. *Why:* the budget exists precisely
for this (D3); wiring the key is what makes it bite.

### D3 — Completion, idempotency, and retry are unchanged
The drain finalizer (`finalize_email_scan_run_if_drained`) already completes a run only when both job
queues are drained, and terminal writes are idempotent on natural keys. Parallel completion of pages
in any order is already handled — nothing to change. A page's transient failure retries under the
task's own policy; the finalizer fails the run only if a page is terminally failed.

### D4 — Cancellation at page boundaries
The orchestrator stops fetching further pages once a `processManagedConnection` reports `cancelled`;
already-dispatched analyses observe `isRunCancellationRequested` at their boundary and fail their job
so the run resolves cancelled. Dispatching the batch does not bypass this — a cancelled run's late
analyses are ignored by the existing check. *Alternative — windowed fetch/analyze overlap* (keep ≤N in
flight while still fetching): more responsive for very large mailboxes but materially more complex;
deferred because fetch is cheap relative to analysis, so batch-after-fetch captures nearly all the
speedup.

## Risks / Trade-offs

- **Cost spike / provider or model rate limits from N-way analysis** → Mitigation: bounded per-user N
  (default 4) under unchanged global/provider ceilings; tune N from telemetry, not guesswork.
- **Fetching all pages before analysis starts** (no overlap) → Mitigation: fetch is metadata-only and
  fast; the cumulative "messages checked" counter climbs during fetch, which reads as healthy
  progress; analysis (the slow part) is what parallelizes.
- **Parent holds its run slot during the fetch phase** → Mitigation: the fetch phase is short; the
  slot is released again during the `batchTriggerAndWait`.
- **A page cap interacts with batching** → Mitigation: respect the existing historical-page cap; the
  batch is simply the pages fetched up to the cap.

## Migration Plan

1. Worker: rework `orchestrateManagedScan` to collect page ids and `batchTriggerAndWait`; trigger each
   with the per-user concurrency key; raise the `INBOX_AGENT_PER_USER_CONCURRENCY` default to 4.
2. Typecheck + tests; redeploy the trigger.dev worker (`npm run trigger:deploy`).
3. Rollback: revert the orchestrator to per-page `triggerAndWait` and/or set
   `INBOX_AGENT_PER_USER_CONCURRENCY=1` (env-only rollback needs no redeploy for the budget half).

## Open Questions

- Final default **N** (4 proposed). Tune against a normal-scan p95 target and observed model/provider
  headroom.
- Is `batchTriggerAndWait` over the whole page set preferable to a bounded window that overlaps fetch
  and analysis? Start with the batch; revisit if very large mailboxes need fetch/analyze overlap.
