## 1. Eval harness baseline (prerequisite)

- [x] 1.1 Assemble a labeled golden-set fixture: sanitized emails → expected proposals/abstains, covering recurring subs, repeated one-offs (Uber/food), novel merchants, and non-English receipts — 18 cases: multi-message merchants, trial-ending, price-change, monthly/quarterly/yearly, EN/ES/DE, plus one-off + non-billing abstains
- [x] 1.2 Build an eval runner that scores a pipeline against the golden set (recall + precision on proposals, plus the Uber-demotion case)
- [x] 1.3 Record the CURRENT per-merchant pipeline's scores as the baseline to meet or beat — ran `npm run eval` on the enriched 18-case set; baseline recorded to `fixtures/eval-baseline.json` (recall 0/11, abstain-clean). NOTE: the 0% baseline is genuinely anomalous (the old pipeline surfaces nothing — likely the classify admit gate); it's the pipeline being replaced, so the real signal is the funnel's absolute score, not "beats baseline"

## 2. Tier-2 read tools and re-scoped authorizer

- [x] 2.1 Extract the amount/interval/spread math from `domain/cadence.ts` into a pure `compute_cadence(message_ids)` tool (drop `classifyRecurrence`/`reconcileRecurrence`) — new `domain/cadence-features.ts` + `agent/tools.ts`; old cadence.ts kept until the gated deletion (6.3) but unused by the agent
- [x] 2.2 Add `list_current_subscriptions` read tool (current tracked subs for reconciliation) — interface + in-memory impl; live DB binding is the seam in 3.4
- [x] 2.3 Add `list_prior_decisions` read tool over prior proposals + outcomes, `reviewed_merchant_aliases`, `merchant_discovery_suppressions`, and `merchant_review_priors` — interface + in-memory impl; live binding is the seam in 3.5
- [x] 2.4 Re-scope `authorizeToolCall` to whole-connected-account read-only; keep fetch sanitize/truncate and a dedicated fetch budget cap — new `agent/authorizer.ts`
- [x] 2.5 Unit-test the new tools + authorizer against injection and out-of-budget cases

## 3. Human-gated propose write

- [x] 3.1 Define the `propose` tool schema: typed/bounded fields only (enums, numbers, ISO dates, merchant from observed set), no free-text notes
- [x] 3.2 Enforce schema validation on `propose` (reject/drop out-of-range or free-text fields before enqueue)
- [x] 3.3 Add the deterministic dedup guard: reject proposals exact-matching an already-tracked or already-rejected/suppressed item
- [ ] 3.4 Wire `propose` into the existing proposal/clarification queue and confirm/edit/reject flow (no subscription mutates without a human tap) — DEFERRED (user): app confirmation-queue integration descoped for now; the autonomous worker persists proposals to `scan_outcomes` (kind='present') instead
- [ ] 3.5 Persist confirm/edit/reject as priors + suppressions consulted on later scans (close the cross-run loop) — DEFERRED (user): follows 3.4; reconcile currently runs with empty in-memory readers
- [x] 3.6 Tests: anti-exfil rejection, dedup idempotency on re-run, edit→prior, reject→suppression — anti-exfil + dedup + reject→suppression covered; edit→prior lands with 3.5

## 4. Tier-2 autonomous agent loop

- [x] 4.1 Replace the per-merchant `select → reason → verify → route` walk with one budgeted, checkpointed agent loop over the look-set — new `agent/agent-graph.ts` (old graph retained until gated cutover)
- [x] 4.2 Author the agent system prompt: emergent grouping, recurrence judgment, reconcile-before-propose, search-first/fetch-sparingly, injection defense
- [x] 4.3 Enforce the per-scan budget (iterations/tool-calls/fetches/tokens/wall-clock) with a guaranteed-termination stop
- [x] 4.4 Implement incremental scanning (only mail since last scan) + targeted per-subscription reconcile searches — `filterIncremental`; targeted reconcile is emergent (agent seeded with current subs)
- [x] 4.5 Tests: termination under budget, one-off-not-proposed, reconcile-not-duplicate, prior-rejection-respected

## 5. Tier-1 look/skip triage

- [x] 5.1 Replace the classifier with a cheap Tier-1 model that reads every email's metadata and returns a discrete look/skip (recall-biased prompt, no numeric cutoff) — new `agent/triage.ts`
- [x] 5.2 Define outage behavior (retry or recall-only fallback) so a triage failure never silently drops mail — recall-only degradation (admit the whole batch)
- [x] 5.3 Compare Tier-1 triage against the old classifier on the golden set (recall must not regress) — funnel recall 100% (4/4) vs baseline 0/4 on the real model; no regression

## 6. Cutover and deletion

- [x] 6.1 Wire the two-tier funnel (Tier-1 look/skip → Tier-2 agent → propose) behind a config flag — `AGENT_MODE=autonomous` selects `runAutonomousLoop` in `worker.ts` (old per-merchant loop is the default, untouched); proposals persist via `finishAutonomousJob` → `scan_outcomes`; unit-tested with a fake store. Also fixed a latent `db.ts` parameter-property that broke type-stripping at runtime
- [x] 6.2 Run the full funnel against the golden set; require it to meet or beat the step-1.3 baseline — PASS on the enriched 18-case set: funnel 100% recall (11/11), 0 false positives, 0 recurrence errors; baseline 0/11. Added alias-tolerant merchant matching so naming granularity (Anthropic ↔ Anthropic Claude Pro) isn't scored as a miss
- [ ] 6.3 Delete `domain/cadence.ts`, `domain/routing.ts`, the keyword admit-gate + `0.45` threshold in `domain/classifier.ts`, the per-merchant node walk, and the clarify-interrupt branch — HELD (needs confirmation): 6.2 passed, but the baseline is anomalous (see 1.3) and the autonomous path has not had a real-DB/real-inbox smoke test; deleting the working default pipeline is destructive and premature
- [ ] 6.4 Remove/rewrite obsolete tests (`cadence.test.ts`, `routing.test.ts`, `clarify-interrupt.test.ts`); run `npm test` + `npm run typecheck` green — HELD: follows 6.3 (old + new tests currently green together)

## 7. Recall observability in production

- [x] 7.1 Implement the skip-sampling probe: route a bounded random sample of skipped emails through the agent via the same sanitize/truncate path — new `agent/skip-sampling.ts`
- [ ] 7.2 Record agent-would-have-surfaced skips as triage misses and expose the false-negative estimate — SEAM: probe returns the estimate; persistence/telemetry is the live-DB wiring
- [x] 7.3 Make budget caps tunable (per user tier); leave the flag on only after eval + skip-sampling look healthy — `resolveBudget(tier)`; enabling the flag is operational
