## 1. Bound the page analysis (prevention)

- [x] 1.1 Add a per-model-call timeout in `worker/src/llm/client.ts` (`makeChatFn` combines
      `AbortSignal.timeout` with any caller signal; a timeout throws a clear error). Configurable via
      `LLM_REQUEST_TIMEOUT_MS`, default 90s.
- [x] 1.2 Lower the `analyze-inbox-page` task `maxDuration` from 3600s to 600s.
- [x] 1.3 Worker test: a model call that times out rejects with "LLM request timed out…" (so the task
      retries) + `llmRequestTimeoutMs` env parsing.

## 2. Recovery unblocks the run

- [x] 2.1 Migration `202608300004`: redefine `recover_expired_inbox_agent_executions()` so on give-up
      (attempts ≥ 3, or a 10-minute dead-lease backstop) it also fails the linked `scan_jobs` row and
      calls `finalize_email_scan_run_if_drained`. Retryable executions are left for native retry.
- [x] 2.2 DB assertion (rolled back): an expired, exhausted execution → execution failed + its
      scan_jobs failed + run finalized; a live (unexpired) execution untouched.

## 3. Schedule the reaper

- [x] 3.1 pg_cron is installed on the project — schedule directly in SQL (no edge cron needed).
- [x] 3.2a Migration schedules `recover_expired_inbox_agent_executions()` every minute via pg_cron
      (idempotent: unschedule-then-schedule by job name).
- [x] 3.2b (n/a — pg_cron available, so no edge `reap` action.)
- [ ] 3.3 After applying to the live DB, confirm the `reap-inbox-agent-executions` cron job is present
      and firing.

## 4. Verification and release

- [x] 4.1 Worker typecheck + tests green (101); migration compiles against the live schema.
- [ ] 4.2 End-to-end: simulate a stuck page (kill / force a lease expiry) and confirm the run reaches a
      terminal state within a couple of minutes with the other pages' candidates intact.
- [ ] 4.3 Deploy: apply the migration to the live DB + redeploy the trigger.dev worker (timeout +
      maxDuration).
