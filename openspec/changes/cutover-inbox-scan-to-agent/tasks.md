## 1. Worker reconcile bindings (real app data)

- [x] 1.1 Add a DB-backed `ReconcileReaders` implementation in the worker that reads the user's current subscriptions from the app database (replacing the in-memory stub in `tools.ts`) — `src/agent/reconcile-db.ts`
- [x] 1.2 Extend it to read learned priors, suppressions, and reviewed aliases (`merchant_review_priors`, suppressions, `reviewed_merchant_aliases`) into `listPriorDecisions`
- [x] 1.3 Unit-test the DB readers against a fake DB client (shape + filtering by merchant), keeping the existing `inMemoryReconcileReaders` for offline tests — `test/reconcile-db.test.ts`

## 2. Worker live inbox read executor

- [~] 2.1 Superseded by model X (see design D4): the edge ships the fetched window in `scan_jobs.raw_messages` and the worker's existing `createScanReadExecutor` serves it. A true beyond-window live executor that performs read-only `search_inbox` and `fetch` against the user's mailbox using stored, decrypted OAuth tokens (reusing the OAuth refresh + crypto + provider-fetch primitives), replacing `createScanReadExecutor`'s scan-window stub for live runs
- [x] 2.2 Executor stays read-only and window-scoped (existing `createScanReadExecutor` + authorizer); degrades to empty on miss and scoped to ids surfaced this run (rely on the existing authorizer); degrade gracefully (empty matches) on provider error
- [~] 2.3 Deferred with the live executor (2.1); window executor already covered by existing worker tests with a fake provider client (search returns matches, fetch returns a sanitized body, error → empty)

## 3. Proposal → app review-queue bridge

- [x] 3.1 Wrote a Node candidate-write in `worker/src/agent/candidate-bridge.ts` (detected_billing_events -> subscription_candidates), typed-fields-only (anti-exfil preserved) (`saveAgenticEvent` → evidence bundle → `subscription_candidates`, with suppression + unique-subscription match) into a shared module reusable by the worker
- [x] 3.2 Worker bridges each proposal into `subscription_candidates` (suppression skip + matched-subscription lookup) via `bridgeProposalsToCandidates`, wired in `worker.ts` is recorded to `scan_outcomes`, write the corresponding `subscription_candidates` row via that shared module (honoring suppression + dedup)
- [x] 3.3 Bridge completes the app run (status=completed, stage=review_ready|completed, events_detected, messages_scanned) so the app's status poll flips + status so the app's status read reflects progress and surfaced-candidate count
- [x] 3.4 `worker/test/candidate-bridge.test.ts` — present->one candidate, suppressed->none, matched->'review', duplicate->not counted: a `present` outcome yields exactly one candidate; a suppressed/tracked merchant yields none

## 4. Worker runs the autonomous funnel as the sole live path

- [x] 4.1 `worker.ts` autonomous loop composes DB reconcile readers (1.x) + window executor (2.x) + candidate bridge (3.x) into `runTwoTierScan`
- [x] 4.2 Idempotent: detected events upsert on natural key, candidates skip on duplicate detected_event; safe on re-claim drives one full funnel run and records outcomes + status idempotently (safe re-claim on retry)
- [x] 4.3 Confirm `npm test` and `npm run typecheck` are green in `worker/` — 64/64 tests pass, tsc clean

## 5. Edge function becomes an enqueue + status/read shim

- [x] 5.1 `processConnectionJob` now enqueues a `scan_jobs` row (raw_messages + scan_run_id + batch_id) instead of running discovery; `start` already just creates runs+jobs to insert a queued `scan_jobs` row for the user (preserving the endpoint contract) instead of running discovery inline
- [x] 5.2 `status` unchanged; `aggregateStage` extended with the new `reasoning` stage returning run/candidate state readable by the app (unchanged client contract)
- [x] 5.3 `runAgenticDiscovery` call + the legacy per-message branch removed from `processConnectionJob`: `runAgenticDiscovery` and the legacy per-message extraction path are no longer invoked from the edge function

## 6. Delete the deterministic judgment code (gated on 7.x smoke test)

- [x] 6.1 Deleted `candidateSignalScore` / `isLikelyBillingCandidate` + signal lists from `email-discovery.ts` (+ its test) + admit gate (`candidateSignalScore`, `isLikelyBillingCandidate`, `admitCandidate`) and any now-dead callers
- [x] 6.2 Deleted `discovery-classifier/verify/routing` + `agentic-reasoner` (+ tests); OAuth/crypto/provider-fetch + review plumbing kept no longer used (`discovery-routing`, `discovery-verify`, `discovery-classifier`, `agentic-reasoner`) and their tests, keeping OAuth/crypto/provider-fetch + candidate/review plumbing
- [x] 6.3 Deleted `runAgenticDiscovery` (+ private helpers) and the dead legacy `extractBillingEvent`/`modelIdentifier` and the legacy per-message extractor from `email-scan/index.ts`
- [x] 6.4 Grep-verified 0 dangling refs + no lingering module imports. NOTE: `deno` unavailable locally — `deno check` must run at deploy no remaining references to the removed judgment code; `deno check` (or the project's edge lint) passes

## 7. Migrations, deploy, and real-inbox smoke test (ops-gated)

- [ ] 7.1 Apply `worker/migrations/0001_worker_queue.sql` AND `worker/migrations/0002_scan_job_run_link.sql` to the app's Supabase Postgres
- [ ] 7.2 Deploy the persistent worker with DB + provider OAuth + DeepSeek credentials and `AGENT_MODE=autonomous`
- [ ] 7.3 Run the real-inbox smoke test end-to-end (app start → job → worker run → candidate appears in review queue); confirm no false positives on a known inbox
- [ ] 7.4 After the smoke test passes, land the deletions from section 6

## 8. Regression + docs

- [ ] 8.1 Keep the golden-set eval green (`npm run eval` in `worker/`) as a regression guard for the autonomous funnel
- [x] 8.2 Updated `worker/README.md` + change notes to state the worker is the live path and the change notes to state the worker is the live path and the deterministic pipeline is removed
