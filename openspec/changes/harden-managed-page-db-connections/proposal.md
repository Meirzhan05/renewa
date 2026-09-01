## Why

Managed `analyze-inbox-page` runs are failing with `TASK_RUN_UNCAUGHT_EXCEPTION: timeout exceeded when trying to connect` inside `PostgresSaver.putWrites`, which shows in the app as a scan that stays at "0" and never updates. The failure is not the pooler choice (the worker is already on the transaction pooler, `:6543`); it is that the page's single shared DB connection is configured to be idle-closed after 10s — shorter than the LLM calls it sits behind — so it is forced to reconnect after every model call, and each reconnect gets only a 10s budget. Worse, the resulting DB error escapes the task's graceful retry handling as an *uncaught* exception, so the terminalize/backstop logic we already shipped is bypassed.

## What Changes

- Keep the page's DB connection alive across long LLM calls: raise the pool's `idleTimeoutMillis` above the page duration ceiling (or disable idle-close for this pool) so a connection is not destroyed mid-page while the reasoner is running.
- Make connection acquisition tolerant of transient pooler pressure: widen `connectionTimeoutMillis` and give the pool enough headroom (`max >= 2`) that the 45s heartbeat query never contends with a checkpoint write for the single connection.
- Guarantee DB errors during page execution are handled through the graceful retry path and can **never** surface as an uncaught task crash: the heartbeat's fire-and-forget `pool.query` must not leave an unhandled rejection, and any detached checkpoint-write failure must be contained.
- Revisit whether a single-shot page analysis needs *Postgres* checkpointing at all (it already falls back to `MemorySaver`); decide in design whether to keep hardened `PostgresSaver` or drop to `MemorySaver` for the page graph. **(design decision — resolved in design.md)**

## Capabilities

### New Capabilities
- `managed-page-execution`: how a single managed inbox-page analysis acquires and holds its database connection across long model calls, and how it must contain database failures so they flow through the durable retry ledger instead of crashing the task.

### Modified Capabilities
<!-- None: there are no existing committed specs; connection/retry behavior for the page task was implicit until now. -->

## Impact

- `worker/src/managed/database.ts` — pool options (`idleTimeoutMillis`, `connectionTimeoutMillis`, `max`) and, depending on the design decision, whether the checkpointer is `PostgresSaver` or `MemorySaver`.
- `worker/src/managed/config.ts` — `loadManagedDatabaseConfig` pool sizing / new tunables and their defaults.
- `worker/src/trigger/analyze-inbox-page.ts` — `withExecutionHeartbeat` floating `pool.query` must not produce an unhandled rejection; confirm all DB-error paths reach the existing `retryable`/`failed` handling.
- No database schema change. Interacts with the already-shipped terminalize/backstop work (`complete_inbox_agent_execution`, `recover_exhausted_inbox_agent_retries`) — this change reduces how often those backstops are needed by keeping failures in-task and graceful.
- Runtime/config only for operators: no app-facing API change; behavior change is "scans stop dying on a mid-page reconnect."
