## Context

Three generations of the inbox scanner coexist in the tree:

- **Gen 1 (live default):** `supabase/functions/email-scan/index.ts` else-branch + `_shared/email-discovery.ts` — keyword prefilter (`candidateSignalScore ≥ 2`) → per-message LLM extraction → deterministic reconcile.
- **Gen 2 (flag-gated off):** `runAgenticDiscovery` + `_shared/discovery-*` — classifier → keyword-fallback admit gate → per-merchant agentic loop → `verifyAssessment` → `routeAssessment` (`minConfidence 0.35`).
- **Gen 3 (built, tested, eval 100% recall / 0 FP, never wired):** `worker/src/agent/*` — Tier-1 LLM triage (no threshold) → one autonomous agent that groups, judges recurrence, reconciles, and proposes.

The app calls `POST /functions/v1/email-scan` and reads `subscription_candidates`. The `worker/` service is a persistent Node + LangGraph process (per its README) meant to *replace* the edge pipeline, but three seams were left open: (1) enqueue-from-app is not wired, (2) the tool executor is a scan-window stub with no live Gmail read, (3) `ReconcileReaders` are empty in-memory stubs. This change closes those seams, routes live scans through Gen 3, and deletes the Gen-1/Gen-2 judgment code.

## Goals / Non-Goals

**Goals:**
- The LLM alone decides include/withhold; no keyword score, threshold, or routing ladder gates candidates.
- Preserve human confirmation (decision 1a) and the existing iOS endpoint + `subscription_candidates` contract (no app change).
- Route live scans through the persistent worker (decision 2a).
- Bind the worker to real inbox reads and real app data (reconcile).
- Remove the deterministic judgment code (Gen 1 + Gen 2), keep the guardrails.

**Non-Goals:**
- Auto-adding subscriptions without confirmation (that was decision 1b, explicitly declined).
- Redesigning the iOS review UI.
- Changing the guardrail contracts (authorizer / budget / typed `propose` / dedup) — they stay as-is.
- Building a brand-new agent; Gen 3 already exists and is the target.

## Decisions

### D1 — Promote Gen 3 (`worker/src/agent/*`) as the single live path; retire Gen 1 & Gen 2.
The autonomous funnel already meets the eval bar and matches the product intent. Rationale: it is the only path with no deterministic judgment. Alternative considered: keep Gen 2 and just remove its keyword fallback — rejected, because Gen 2 still has the routing ladder and a per-merchant deterministic walk, and it duplicates an engine we already have working.

### D2 — Worker queue tables live in the same Supabase Postgres as the app.
`worker/migrations/0001_worker_queue.sql` (`scan_jobs` / `scan_outcomes`) is applied to the app's Postgres so the edge function can `INSERT` a job and the worker can read app tables (subscriptions, priors, suppressions, aliases, `subscription_candidates`) in the same database. Alternative: a separate worker DB with a sync bridge — rejected as needless cross-DB plumbing for a single-tenant backend.

### D3 — The worker writes `subscription_candidates` directly (single owner of the write).
After recording a `present` outcome, the worker performs the same candidate upsert the edge function does today (`saveAgenticEvent` → evidence bundle → `subscription_candidates`, honoring suppression + unique-subscription match). Rationale: one service owns the write transactionally and reuses the existing iOS-facing contract. Alternatives: a DB trigger copying `scan_outcomes → subscription_candidates` (opaque, harder to test) or the edge function polling outcomes (reintroduces a seam). The candidate-write helpers move from the edge function into a shared/worker module so both the deletion and the worker reuse one implementation.

### D4 — Provider read: the edge ships the fetched window in the job; the worker reasons over it (model X). **[Revised during implementation]**
The edge function already fetches the provider batch (metadata + snippet) inside `processConnectionJob`; the cutover has it enqueue that window as the `scan_jobs.raw_messages` payload, and the worker's existing `createScanReadExecutor` serves `search_inbox`/`fetch` over that window. Rationale (why this beat the original plan): (a) it avoids a blind Deno→Node port of the OAuth/crypto/provider-fetch stack — the highest-risk, least-verifiable work; (b) it keeps the expensive step — the agent's tool-using reasoning loop — in the persistent worker, which was the actual wall-clock ceiling the worker exists to remove (metadata fetch was never the bottleneck); (c) it makes the golden-set eval representative, since the eval also runs the window executor (removing the "eval isn't representative" risk from D6). Trade-off: the agent can only search within the fetched window, not the whole mailbox. Accepted for the first cutover (it matches today's coverage); a true beyond-window live executor — using the `googleapis` dep already in `worker/` and the existing `scripts/gmail-scan.ts` — is a follow-up. The original alternative (worker fetches live via stored OAuth tokens) is deferred, not discarded.

### D5 — The edge function becomes a thin enqueue + status/read shim.
`start` inserts a `scan_jobs` row and returns run status; `status` reads run/candidate state. `runAgenticDiscovery` and the legacy per-message branch are deleted. Rationale: preserve the endpoint contract with none of the inline discovery.

### D6 — Deletion is the last step, gated on a real-inbox smoke test.
The eval used the scan-window executor, not live Gmail (per the change notes / memory). So the cutover order is: wire worker end-to-end → point the edge function at the queue → run a real-inbox smoke test (`AGENT_MODE=autonomous`) → then delete Gen-1/Gen-2 code. Rollback before deletion is a git revert of the edge shim (re-enabling the inline path); after deletion, rollback is a revert of the deletion commit.

## Risks / Trade-offs

- **[Live Gmail read differs from the eval's scan-window executor]** → Gate deletion on a real-inbox smoke test (D6); keep the eval harness green as a regression guard; start the search executor read-only and id-scoped so a bad query cannot exceed authorized scope.
- **[Persistent worker is new infra with a failure mode the edge function didn't have]** → Worker must be idempotent per job (claim/lease semantics already in the queue schema); jobs that error are retried, not lost; triage degrades recall-only on model outage. A stuck worker means scans queue rather than produce wrong results.
- **[Prompt-injection surface grows once bodies are fetched live]** → Unchanged guardrail posture: untrusted-content system prompt, read-only tools, typed `propose` with no free-text field (the anti-exfil wall stays exactly as built).
- **[Cost/latency of an autonomous loop over a real inbox]** → Tier-1 triage caps what the expensive agent sees; the per-run budget bounds tokens/tool-calls/wall-clock; monitor via the per-run agent counters already persisted.
- **[Two DBs of truth for a candidate]** → Avoided by D3: the worker writes `subscription_candidates` directly; `scan_outcomes` is the run ledger, not a second source the app reads.

## Migration Plan

1. Apply `worker/migrations/0001_worker_queue.sql` to the app's Supabase Postgres (D2).
2. Wire the worker: DB-backed `ReconcileReaders`, live provider read executor, direct `subscription_candidates` write (D3/D4); confirm `npm test` + `tsc` green.
3. Point the edge function `start`/`status` at the queue (D5) behind a deploy; the legacy inline path stays in git history for rollback.
4. Deploy the persistent worker with DB + OAuth + DeepSeek credentials and `AGENT_MODE=autonomous`.
5. Run the real-inbox smoke test (D6).
6. On success, delete Gen-1/Gen-2 judgment code and the now-dead `discovery-*` / keyword-scorer modules.

**Rollback:** pre-deletion, revert the edge shim commit to restore inline discovery; post-deletion, revert the deletion commit.

## Open Questions

- Where is the persistent worker deployed (Fly.io / Render / a small VM)? — an ops choice, does not block the code wiring.
- Does the worker fetch on a fixed scan window or true incremental (push-token) cursor for the first live cutover? — start with the existing window semantics, revisit under the push-monitoring work.
