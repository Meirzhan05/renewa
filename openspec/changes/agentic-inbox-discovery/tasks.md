## 1. Foundations & flags

- [x] 1.1 Add env/config for the scan feature flag and tier-1 classifier (`CLASSIFIER_BASE_URL`, `CLASSIFIER_API_KEY`, `CLASSIFIER_MODEL`), with `.env.example` entries and a documented DeepSeek fallback when unset
- [x] 1.2 Add a shared OpenAI-compatible chat helper (base URL + key + model) so tier-1 and tier-2 share one request/parse/timeout path
- [x] 1.3 Migration: `discovery_near_misses` (user_id, run_id, canonical_merchant_key, existence, completeness, missing_fields, reason, created_at) + per-run agent-budget columns on the runs table; RLS owner-only select, cascade delete, service_role writes

## 2. Tier-1 wide classifier

- [x] 2.1 Implement `classifyCandidates(metadata[])` in `_shared/email-discovery.ts`: metadata+snippet only, batched, returns `{message_id, relevant, confidence, merchant_guess, rank}`
- [x] 2.2 Wire the classifier as the admit gate in `processConnectionJob`, replacing the sole `isLikelyBillingCandidate` cutoff; keep keyword score as one input and as the degradation fallback
- [x] 2.3 Group admitted messages into per-merchant evidence bundles keyed by resolved merchant (reuse `canonicalMerchantKey` + reviewed-alias resolution)
- [x] 2.4 Unit tests: terse-receipt admitted, marketing excluded, grouping of two emails, classifier-outage falls back to keyword gate, full body never sent to tier-1

## 3. Tier-2 agentic reasoning loop

- [x] 3.1 Define the loop's tool schema and a server-side authorizer that validates/scopes `search_inbox` (this connection), `fetch` (IDs surfaced this scan), `get_more` (merchant sender domains); reject out-of-scope calls
- [x] 3.2 Implement read-only tool executors backed by the existing Gmail/Microsoft fetch layer (metadata search, full-message fetch, sender fetch), returning sanitized content
- [x] 3.3 Implement `reasonAboutMerchant(bundle, budget)` tool-use loop: assess → optional tool → re-assess → emit structured assessment `{existence, completeness, missing_fields[], fields, evidence_refs[], abstain_reason}`
- [x] 3.4 Enforce the budget envelope: `maxIterations`, `maxToolCalls`, `maxFetches`, `maxTokens`, per-merchant wall-clock; exhaustion emits best-effort reduced-confidence result (never hang, never auto-present)
- [x] 3.5 Enforce per-run `maxMerchantsPerRun` + global token/cost budget; defer overflow merchants to the existing continuation mechanism; record budget accounting on the run
- [x] 3.6 Reinforce untrusted-data discipline in the loop system prompt and prove scope/budget cannot be widened by email content
- [x] 3.7 Unit tests: under-confident loop gathers then concludes; sufficient bundle concludes with no tool call; out-of-scope `fetch` rejected; `get_more` wrong-sender rejected; budget exhaustion path; injection attempt cannot escalate; ungrounded amount left unset

## 4. Extract→verify grounding

- [x] 4.1 Implement `verifyAssessment(assessment, bundle)` (tier-2 cheap call) that grounds each asserted field; strip ungrounded fields, downgrade ungrounded existence to low
- [x] 4.2 Keep amounts never-inferred regardless of verifier; add range/enum re-validation on surviving fields
- [x] 4.3 Unit tests: ungrounded cycle stripped → routed as missing; unsupported existence downgraded to watch

## 5. Confidence-ladder routing

- [x] 5.1 Implement two-axis router: (high+complete)→present candidate; (high+incomplete)→raise `billing_cycle_check` (and analogous) clarification; (low)→persist near-miss, no prompt
- [x] 5.2 Feed the verified assessment into `reconcileMerchantLifecycle`; map "high existence, missing cycle" away from `uncertain` into the clarification path
- [x] 5.3 Persist near-misses and abstain reasons to `discovery_near_misses`; stop discarding `abstainReason`
- [x] 5.4 Confirm the human-confirmation gate on every surfaced path (present + ask both require confirm; nothing auto-tracks)
- [x] 5.5 Unit tests: strong-but-incomplete → one clarification; complete → candidate; weak → near-miss only; presented candidate not tracked until confirmed

## 6. Orchestration, metrics, rollout

- [x] 6.1 Rewire `processConnectionJob` end to end: classify → group → reason → verify → route; behind the feature flag, with the legacy per-message path as the flag-off fallback
- [x] 6.2 Emit per-run counters (candidates, presented, asked, near-miss, abstain, tool calls, approx cost) into the run record for observability
- [x] 6.3 `deno check` + `deno test` clean for `email-scan` and `_shared`; no regression in existing discovery tests
- [ ] 6.4 Dogfood on the developer's own Gmail: run a live scan, confirm a real paid subscription that previously fell into "needs more evidence" now surfaces as candidate or clarification, and confirm counters/budget look sane
