## 1. Swap the page checkpointer to in-process MemorySaver

- [x] 1.1 In `worker/src/managed/database.ts`, construct the page pool directly and use `MemorySaver` instead of `PostgresSaver`; update `close()` to `pool.end()` (no longer `checkpointer.end()`).
- [x] 1.2 Update the `ManagedDatabase.checkpointer` type to the LangGraph `BaseCheckpointSaver`/`MemorySaver` so `analyzeInboxPage` still type-checks. (also updated `page-analysis.ts` param type)
- [x] 1.3 Remove `initializeManagedCheckpointer` / `checkpointer.setup()` usage now that it is dead: removed the function from `database.ts` and its call in `dispatch-inbox-pages.ts`. Left the checkpoint tables in place. (`worker.ts` old pipeline keeps its own PostgresSaver — out of scope.)

## 2. Harden the pool configuration

- [x] 2.1 In `worker/src/managed/database.ts`, set pool options so the connection survives a page: `idleTimeoutMillis: 0`, `keepAlive: true`, and `connectionTimeoutMillis` raised to 15000ms.
- [x] 2.2 In `worker/src/managed/config.ts`, default `MANAGED_DATABASE_POOL_MAX` to 2 (kept overridable) and rewrote the comment to reflect heartbeat isolation.
- [x] 2.3 Global-capacity math (4 × 2 = 8 ≤ transaction pooler) noted in the `config.ts` comment.

## 3. Contain database failures so the task never crashes

- [x] 3.1 Extracted the heartbeat tick into a self-catching `heartbeatOnce` (log-and-drop, never rejects); `withExecutionHeartbeat` now calls it, so a rejected heartbeat cannot become an unhandled rejection.
- [x] 3.2 Reviewed the page body: the only floating promise was the heartbeat (now contained); every other DB op is `await`ed inside the `retryable`/`failed` try/catch, and MemorySaver removes detached checkpoint writes.

## 4. Tests

- [x] 4.1 Added `managed-database.test.ts` cases: pool built with `idleTimeoutMillis: 0`, `connectionTimeoutMillis: 15000`, `keepAlive: true`; `poolMax` default 2 with env override honored.
- [x] 4.2 Added a test asserting the page checkpointer `instanceof MemorySaver` (never `PostgresSaver`).
- [x] 4.3 Added `heartbeat.test.ts`: `heartbeatOnce` swallows a rejecting query (never rejects) and issues the heartbeat with the execution id.
- [x] 4.4 `npm run typecheck` clean; `npm test` green (111/111, including the 6 new/updated cases).

## 5. Verify against a live scan

- [ ] 5.1 Restart `trigger dev`, run one scan, and confirm the page completes (or fails gracefully as `retryable`/`failed`) instead of dying with `timeout exceeded when trying to connect` at `PostgresSaver.putWrites`.
- [ ] 5.2 Confirm no `TASK_RUN_UNCAUGHT_EXCEPTION` in the run trace for a DB blip.
