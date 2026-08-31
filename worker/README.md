# Renewa Agent Worker

A **persistent backend service** that runs the Renewa inbox agentic-discovery pipeline as a
[LangGraph](https://langchain-ai.github.io/langgraphjs/) state machine. It replaces the pipeline
that lived inside the ephemeral Supabase Edge Function (`supabase/functions/email-scan`) with a
long-lived worker, whose key advantage is **durable human-in-the-loop**: a scan that needs to ask
the user a question pauses (a checkpointed `interrupt`), survives restarts, and resumes the *same*
run days later when the answer arrives — no reconstruct-the-state seam.

## Why this exists

The edge function runs for a few seconds and dies, so a clarification ("How often do you pay for
Anthropic?") had to be a separate DB round-trip that rebuilt state on the answer — the seam where a
cascade of bugs lived. A persistent worker + a Postgres checkpointer lets one graph run span the
pause, and it removes the runtime ceiling on the tool-using reasoning loop.

## Pipeline (the graph)

```
classify ─▶ select ─▶ reason ⇄ tools ─▶ verify ─▶ route ─┬─▶ present   (candidate)
             ▲                                            ├─▶ clarify   (interrupt ⇄ resume)
             └────────────── next merchant ──────────────┴─▶ near_miss (logged)
```

- **classify** — cheap tier-1 pass; admits subscription-relevant mail and groups it by merchant
  (`src/domain/classifier.ts`).
- **reason ⇄ tools** — per-merchant tier-2 loop inside a budget. The model *proposes* read-only
  tool calls; `authorizeToolCall` *authorizes* them against merchant scope
  (`src/domain/reasoner.ts`, executed by `src/executor.ts`).
- **verify** — grounds each asserted field against the evidence, then the **recurring-vs-one-off**
  guard (`src/domain/cadence.ts`) demotes repeated one-off purchases (Uber rides, food orders) so
  they are not mistaken for a subscription.
- **route** — two-axis ladder → present / clarify / near-miss (`src/domain/routing.ts`).
- **clarify** — a durable `interrupt()`; the run pauses and resumes with the user's answer.

The wiring is `src/graph/graph.ts`; the persistent loop is `src/worker.ts`.

## Safety

Read-only tools only; no tool writes, tracks, or sends. Email content is untrusted — the model may
propose a tool call, but the pure authorizer decides what is allowed (fetch only ids already
surfaced this scan; `get_more` only for the merchant's own domains). A per-merchant budget
(iterations / tool calls / fetches / tokens / wall-clock) guarantees termination. The human
confirmation gate is preserved: present and clarify both still require the user to confirm.

## Development commands

```bash
npm install
npm start                # intentionally prints guidance; it never starts agents
npm run worker:local     # legacy local worker, only when deliberately testing it
npm run trigger:dev      # managed development runner, only when deliberately testing it
```

The managed runner needs development-only `TRIGGER_PROJECT_REF`, `TRIGGER_SECRET_KEY`,
`MANAGED_AGENT_SHARED_SECRET`, `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`,
`MANAGED_DATABASE_URL`, and model configuration. Keep them in an ignored environment file, never
in the app or task payload. The public Supabase key is required only to reach the protected
Function; it is not a service-role credential. For hosted Supabase, the managed URL
must be the **Transaction pooler** connection string (port `6543`) and
`MANAGED_DATABASE_REQUIRE_TRANSACTION_POOLER=true`; local Postgres may use its ordinary URL.
Start conservatively with a one-connection pool, global/provider capacity of four, and one page per
user. `MANAGED_INBOX_AGENT_ENABLED` stays unset/false until the staged backend rollout is ready.

## Managed workflow path

When `MANAGED_INBOX_AGENT_ENABLED=true`, the `email-scan` Edge Function starts one managed
`scan-inbox-run` task per connected inbox. It advances provider pages without an iOS follow-up
request and records a page execution for each page. The scheduled `dispatch-inbox-pages` task
leases a small, fair selection from PostgreSQL every minute, submits individual
`analyze-inbox-page` tasks, and records their Trigger runtime IDs. PostgreSQL, not a local
`npm start` process, owns global/provider/per-user admission, retry, cancellation, stale-lease
recovery, and final scan status.

Managed task payloads contain only versioned run/page identifiers. A task calls the protected Edge
Function just in time to claim work and receive a refreshed provider credential in memory; it never
persists that credential to Trigger.dev, `scan_jobs`, or the managed execution ledger. The pipeline
then reconciles proposals and writes review-first candidates through the existing bridge.

Rollback: set `MANAGED_INBOX_AGENT_ENABLED=false` before disabling the Trigger runner. Existing
managed work finishes or is cancelled through the app; new scans then use the explicit legacy path
while the ledger remains available for audit. Do not turn the flag on until the corresponding
Supabase migration/function secrets and the Trigger development runner have been verified.

## Operating the dispatcher

`npm start` is intentionally inert: it never starts an agent. In development, run
`npm run trigger:dev` only while testing managed scans; Trigger schedules are active only while that
development runner is connected. In production, deploy the Trigger project and do not run a local
worker process.

**Environment contract (must hold or every scan silently expires).** The `email-scan` Edge Function
dispatches `scan-inbox-run` into the Trigger environment its `TRIGGER_SECRET_KEY` belongs to (a
`tr_dev_…` key targets the **dev** environment, `tr_prod_…` the **prod** environment). A live worker
**must** exist in that same environment, or the dispatched run has no version to execute, sits in the
queue, and **EXPIRES at its 10-minute TTL** — the run stays `running`, no candidate is produced, and
the app shows 0 forever. So: with a **dev** key, keep `npm run trigger:dev` connected while scanning;
for real users, put a **prod** key on the edge and `trigger deploy` the worker. A stalled run is now
failed within `SCAN_DISPATCH_GRACE_MS` (default 12m ≥ the run TTL) by the edge classifier on the next
poll and by the `recover_stalled_inbox_scan_runs()` pg_cron backstop even with no poll — surfacing
"Scan worker is unavailable" instead of a silent hang, but that is a safety net, not a substitute for
a live worker.

Watch `inbox_agent_executions` by state, the age of `leased`/`running` rows, retryable counts, and
database connection usage. A lease is recoverable after two minutes; after three attempts it fails
the page and finalizes the run instead of leaving it permanently “preparing”. To stop a scan, use
the visible **Stop** action in Inbox: queued and leased pages are cancelled immediately, while an
active page stops at its next safe boundary. Do not kill a worker as routine cancellation.

Increase `INBOX_AGENT_GLOBAL_CONCURRENCY` only after observing stable connection use. Keep
`MANAGED_DATABASE_POOL_MAX=1`, tune provider limits to the providers' quotas, and retain the
per-user limit at one unless fairness has been load-tested. Roll back by disabling the managed flag,
then let in-flight work finish or stop it through the app.

## Legacy worker deployment

The worker below is legacy migration support only; managed Trigger tasks remove the production
dependency on an always-on `npm start` process. Do not deploy or restart this worker as part of the
managed rollout unless intentionally rolling back.

```bash
fly apps create renewa-worker        # or edit `app` in fly.toml to your name
fly secrets set \
  DATABASE_URL="postgres://...supabase..." \
  DEEPSEEK_API_KEY="sk-..." \
  --app renewa-worker
fly deploy --app renewa-worker
```

`DATABASE_URL` must be the **same Postgres as the Supabase app** (so the worker reads the
edge-enqueued `scan_jobs` and writes `subscription_candidates`). Apply
`migrations/0001_worker_queue.sql` and `migrations/0002_scan_job_run_link.sql` there first.
`AGENT_MODE=autonomous` is set by the image/`fly.toml`. Tail logs with `fly logs`.

## Develop

```bash
npm test        # node --test — one suite per feature, no network
npm run typecheck
```

Every graph node is a thin wrapper over a pure function in `src/domain/`, so the whole pipeline is
tested with an injected fake model and executor (`test/`) — including the Uber demotion
(`graph.test.ts`) and the interrupt/resume cycle (`clarify-interrupt.test.ts`).

Requires Node ≥ 22.6 (runs TypeScript directly via type-stripping).
