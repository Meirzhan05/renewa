## Context

`analyze-inbox-page` runs one inbox page (~100 messages) as a short-lived Trigger.dev task. `worker/src/managed/database.ts` builds **one** `pg` Pool with `max: 1`, `idleTimeoutMillis: 10_000`, `connectionTimeoutMillis: 10_000`, and hands it to *both* the `PgJobStore` and a LangGraph `PostgresSaver` checkpointer. Inside a page, `runTwoTierScan` runs Tier‑1 triage (LLM), then `app.invoke` runs the Tier‑2 graph, which interleaves reasoner **LLM calls** (10–90s) with **checkpoint writes** and **reconcile reads** on that single connection. A 45s heartbeat also fires `pool.query` on the same pool.

Because `idleTimeoutMillis` (10s) is shorter than an LLM call, the one connection is destroyed while a model call is in flight and must be re-established on the next DB op. Each reconnect gets only a 10s budget; under any transaction-pooler pressure it fails with `timeout exceeded when trying to connect` — landing on `PostgresSaver.putWrites`, the first DB op after the reasoner call. The worker is already on the transaction pooler (`:6543`), so this is not a pooler-selection problem.

Separately, the failure surfaces as `TASK_RUN_UNCAUGHT_EXCEPTION`, meaning it bypassed the task's own try/catch (which would have completed the execution as `retryable`/`failed`). The likely escapes are the heartbeat's fire-and-forget `void pool.query(...)` (no `.catch`) and detached checkpoint writes scheduled off the `await app.invoke` path.

Related shipped work: `complete_inbox_agent_execution` now caps retries at 3 and finalizes on `failed`; `recover_exhausted_inbox_agent_retries` is the reaper backstop. Those keep a crash from looping forever, but only after the lease expires — the page still dies noisily and the app sits at "0".

## Goals / Non-Goals

**Goals:**
- A page's DB connection survives across its LLM calls; no forced mid-page reconnect on a normal in-page gap.
- Connection acquisition tolerates brief transaction-pooler pressure (budget/headroom), and the heartbeat never contends with a checkpoint/store op for the only connection.
- No DB error during a page can escape as an uncaught task exception; every DB failure flows through the existing `retryable`/`failed` ledger path.
- Reduce, not just survive, the reconnect churn that creates the failure in the first place.

**Non-Goals:**
- No database schema change; no change to the dispatcher, lease reaper, or terminalize logic already shipped.
- No change to pooler selection (transaction pooler `:6543` stays; the enforcement flag stays).
- Not re-architecting the two-tier funnel or the graph itself.

## Decisions

### Decision 1: Drop `PostgresSaver` for the page graph; use `MemorySaver`

Use an in-process `MemorySaver` for the page's LangGraph checkpointer instead of `PostgresSaver`. The pool is then used only by `PgJobStore`, reconcile reads, and the heartbeat.

**Why:** `PostgresSaver.putWrites` is the exact failing frame, and checkpoint writes are the *highest-frequency* DB op during the graph (one after every superstep, each sitting behind an LLM call). Dropping them removes the failing path and the detached-checkpoint-write uncaught-rejection risk in one move. The only thing `PostgresSaver` buys is resume-on-redispatch (a re-dispatched page with the same `thread_id: job.id` resumes the Tier‑2 graph from its last checkpoint). That value is low here:
- Tier‑1 triage runs *outside* the graph, so it re-runs on redispatch regardless — Postgres checkpointing only ever resumed the Tier‑2 portion.
- Pages are bounded (~100 messages, `maxDuration` 600s), so re-running Tier‑2 from scratch is affordable.
- Once the connection is hardened, in-page failures — and therefore redispatches — become rare, so resume value approaches zero.

**Alternatives considered:**
- *Keep `PostgresSaver`, only harden the pool.* Preserves resume, but keeps the fragile, high-frequency DB path and the detached-write escape, and pays PgBouncer-transaction-mode quirks for a benefit we rarely realize. Rejected as more surface area for less safety.
- *Custom checkpointer that batches/no-ops writes.* More code than it saves; `MemorySaver` already is the in-process default and the existing fallback.

### Decision 2: Harden the pool regardless (mandatory)

Even with `MemorySaver`, reconcile reads and the heartbeat still use the pool with LLM-length gaps between ops, so the pool must be hardened:
- **Disable idle-close for the per-page pool** (`idleTimeoutMillis: 0`), or set it comfortably above `maxDuration`. The pool is created and `close()`d per page invocation, so a connection living for the page's lifetime is correct and bounded.
- **`keepAlive: true`** to reduce silent TCP drops during long model calls.
- **Raise `connectionTimeoutMillis`** to ~15–20s to absorb brief pooler pressure on the reconnects that still happen (cold start, dropped socket).
- **`max: 2`** so the 45s heartbeat can acquire its own connection without waiting out a checkpoint/store op. Keep it overridable via `MANAGED_DATABASE_POOL_MAX`; update the default and the "one connection per page" comment.

**Global-capacity math:** `globalConcurrency` (default 4) × `max` (2) = up to 8 pooled connections, well within the transaction pooler's capacity. The dispatcher still bounds concurrent pages.

### Decision 3: No DB error may crash the task

- Add `.catch` to the heartbeat's fire-and-forget `pool.query` so a rejected heartbeat is logged and dropped, never an unhandled rejection.
- With `MemorySaver`, the checkpointer no longer issues detached DB writes, closing the other escape. Confirm every remaining DB op in the page body is inside the existing try/catch that routes to `releaseJobForRetry` + `complete_inbox_agent_execution('retryable'|'failed')`.

## Risks / Trade-offs

- **[Lose resume-on-redispatch]** → A re-dispatched page re-runs the Tier‑2 graph from scratch, re-spending those LLM calls. Mitigation: redispatches are rare once the connection is stable and capped at 3; Tier‑1 already re-ran regardless; pages are small. Net token cost is negligible versus the current 100% failure.
- **[`max: 2` × concurrency raises peak connections]** → Mitigation: 8 peak on the transaction pooler is safe; `MANAGED_DATABASE_POOL_MAX` and `INBOX_AGENT_GLOBAL_CONCURRENCY` remain overridable if a smaller pooler is used.
- **[Disabling idle-close could hold a connection through a stalled page]** → Mitigation: the pool is per-invocation and `maxDuration` (600s) bounds the page; `close()` releases it. `keepAlive` reduces mid-page socket death.
- **[Transaction pooler can still drop a server-side connection]** → That surfaces as a query error, not a connect timeout, and is now caught by the graceful path → `retryable`. Acceptable and correct.

## Migration Plan

1. Code-only change in `worker/` (pool options + `MemorySaver` + heartbeat `.catch`). No migration, no schema change.
2. If `initializeManagedCheckpointer` / `checkpointer.setup()` is now unused, remove that call in the same change (the checkpoint tables can be left in place; dropping them is out of scope).
3. Restart `trigger dev` (local) — env and code are read at startup — then run one scan and confirm the page completes rather than dying at `putWrites`.
4. **Rollback:** revert the worker change; behavior returns to the prior `PostgresSaver` + `max:1` config. No data to unwind.

## Open Questions

- Should `MANAGED_DATABASE_POOL_MAX` default to 2 (chosen here) or stay 1 with the idle-close fix alone? Leaning 2 for heartbeat isolation; revisit if pooler capacity is tight.
- Is `initializeManagedCheckpointer` referenced anywhere still needed after Decision 1? Verify during apply and remove if dead.
