## 1. Concurrency budget default

- [x] 1.1 Raise `INBOX_AGENT_PER_USER_CONCURRENCY` default from 1 to 4 in
      `worker/src/managed/config.ts` (via a standalone, secret-free `perUserAnalysisConcurrency`
      reader); keep it env-overridable and validated as a positive integer.
- [x] 1.2 Apply the value as the `analyze-inbox-page` queue's per-key `concurrencyLimit`, so with the
      per-run concurrency key it bounds per-user parallelism.

## 2. Orchestrator fan-out

- [x] 2.1 Rework `orchestrateManagedScan` (`worker/src/trigger/scan-inbox-run.ts`) to fetch pages
      sequentially and collect their ids, breaking on cancellation.
- [x] 2.2 Replace the per-page `triggerAndWait` with a single `analyzeInboxPageTask.batchTriggerAndWait`
      over the collected pages; each item keeps its `pageAnalysisIdempotencyKey` and a per-run
      `pageAnalysisConcurrencyKey`, extracted into a testable `pageAnalysisBatchItems` helper.
- [x] 2.3 Preserve the return contract (`{ cancelled, pagesProcessed }`): `cancelled` derives from a
      cancelled fetch or any cancelled page result; completion stays owned by the drain finalizer.
- [x] 2.4 Keep the fetch-time cancellation short-circuit (stop collecting and dispatch nothing once a
      page reports cancelled).

## 3. Tests

- [x] 3.1 Orchestrator test: given K fetched pages, all K are dispatched in one batch (fetches happen
      before the batch, not interleaved).
- [x] 3.2 Test that a cancelled fetch dispatches no analysis.
- [x] 3.3 Test that a cancelled page result surfaces as `cancelled` in the orchestrator return.
- [x] 3.4 Test that `pageAnalysisBatchItems` attaches a per-page idempotency key and a shared per-run
      concurrency key to every item.

## 4. Verification and release

- [x] 4.1 Worker typecheck clean + tests green (99 pass).
- [ ] 4.2 Redeploy the trigger.dev worker; run a multi-page scan and confirm pages analyze in parallel
      (several `analyze-inbox-page` runs active at once) and wall-clock time drops ~N×.
- [ ] 4.3 Confirm correctness end to end: no duplicate candidates, run finalizes once after the last
      page, cancellation stops further analysis.
