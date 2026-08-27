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
npm start                 # begins polling scan_jobs
```

Enqueue a scan by inserting a `scan_jobs` row (the app or an edge function does this). Answer a
clarification by setting `scan_clarifications.answer` and `status = 'answered'`; the worker resumes
the run on its next tick and writes results into `scan_outcomes`.

## Develop

```bash
npm test        # node --test — one suite per feature, no network
npm run typecheck
```

Every graph node is a thin wrapper over a pure function in `src/domain/`, so the whole pipeline is
tested with an injected fake model and executor (`test/`) — including the Uber demotion
(`graph.test.ts`) and the interrupt/resume cycle (`clarify-interrupt.test.ts`).

Requires Node ≥ 22.6 (runs TypeScript directly via type-stripping).
