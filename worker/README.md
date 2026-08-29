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

## Run it

```bash
npm install
cp .env.example .env      # fill in DATABASE_URL + DEEPSEEK_API_KEY
psql "$DATABASE_URL" -f migrations/0001_worker_queue.sql
psql "$DATABASE_URL" -f migrations/0002_scan_job_run_link.sql
AGENT_MODE=autonomous npm start   # live path: begins polling scan_jobs
```

Enqueue a scan by inserting a `scan_jobs` row — the `email-scan` edge function now does this: on a
scan it fetches the mailbox window and enqueues a `scan_jobs` row (`raw_messages` + `scan_run_id` +
`batch_id`) instead of running discovery itself.

## Live path (post-cutover)

As of the `cutover-inbox-scan-to-agent` change, **the worker's autonomous two-tier funnel
(`AGENT_MODE=autonomous`, `src/agent/*`) is the live discovery path.** The deterministic pipeline
that used to run inside the edge function — the keyword prefilter (`candidateSignalScore` /
`isLikelyBillingCandidate`), the per-merchant agentic path (`runAgenticDiscovery`), the routing
ladder (`routeAssessment`), and the legacy per-message extractor — has been removed. The include /
withhold decision is now entirely the LLM's; a human still confirms every candidate.

Flow: app `start` → edge fetches the window + enqueues `scan_jobs` → worker runs triage → agent →
propose, reconciles against the user's real subscriptions/priors/suppressions
(`src/agent/reconcile-db.ts`), and bridges each proposal into the app's `detected_billing_events` →
`subscription_candidates` review queue and completes the run (`src/agent/candidate-bridge.ts`). The
app reads candidates through its existing endpoint, unchanged.

## Develop

```bash
npm test        # node --test — one suite per feature, no network
npm run typecheck
```

Every graph node is a thin wrapper over a pure function in `src/domain/`, so the whole pipeline is
tested with an injected fake model and executor (`test/`) — including the Uber demotion
(`graph.test.ts`) and the interrupt/resume cycle (`clarify-interrupt.test.ts`).

Requires Node ≥ 22.6 (runs TypeScript directly via type-stripping).
