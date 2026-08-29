## Why

The autonomous, fully-LLM inbox scanner already exists in `worker/src/agent/*` — it was built,
unit-tested (64 tests green), and passed its golden-set eval at 100% recall / 0 false positives —
but it was never connected to the app. A prior session was supposed to wire it and did not. So the
code users actually run is still the **legacy edge-function pipeline** (`AGENTIC_DISCOVERY` is off
by default), whose include/exclude decision is made by **hand-tuned deterministic code**: a keyword
scorer (`candidateSignalScore ≥ 2`), an admit threshold (`admitCandidate`), and a fixed routing
ladder (`routeAssessment`, `minConfidence 0.35`). This is exactly the "manual code written for
filtering subscriptions" we want gone. This change promotes the autonomous engine to the live path
and deletes the deterministic judgment code.

## What Changes

- **The LLM makes the include/withhold decision.** A cheap Tier-1 LLM triage (`look/skip`, no
  numeric cutoff) narrows the inbox; a single autonomous Tier-2 agent then groups merchants, judges
  recurring-vs-one-off, reconciles against what the user already tracks, and PROPOSES candidates.
  No keyword score, no confidence threshold, no deterministic routing ladder decides what surfaces.
- **The human confirmation gate is preserved (decision 1a).** The agent proposes; the user still
  confirms/edits/rejects each candidate. Nothing is auto-added to the app.
- **The `worker/` service becomes the live scan path (decision 2a).** The app's "start scan"
  enqueues a `scan_jobs` row; the persistent worker runs the autonomous funnel and writes results;
  the app reads them back through its existing review queue.
- **Wire the integration seams the engine was built against but never given:**
  - Bind `ReconcileReaders` to the real app DB (current subscriptions, `merchant_review_priors`,
    suppressions, reviewed aliases) instead of the empty in-memory stubs.
  - Bridge worker `scan_outcomes` (kind=`present`) into the app's `subscription_candidates` table so
    the existing iOS review UI works unchanged.
  - Give the worker a real inbox read path (fetch the user's mail via stored OAuth tokens) instead
    of the scan-window-only stub executor.
- **BREAKING (internal): remove the deterministic judgment code.** Delete the Gen-1 keyword
  prefilter + per-message extractor path and the Gen-2 in-edge agentic path, including
  `candidateSignalScore` / `isLikelyBillingCandidate` / `admitCandidate`, `routeAssessment`, and the
  now-dead `discovery-*` modules. The edge function is reduced to an enqueue + status/read shim.
- **Retain all guardrails (not judgment).** The tool authorizer, the per-run budget (termination),
  the typed `propose` schema (anti-prompt-injection wall), and `dedupeProposal` (idempotency) stay —
  these bound a nondeterministic agent; they do not decide what counts as a subscription.

## Capabilities

### New Capabilities
- `autonomous-inbox-scan`: The scan engine's behavior — an LLM triage + a single autonomous agent
  decide which merchants become candidates, with guardrails and human confirmation retained, and
  with no deterministic keyword/threshold/routing judgment.
- `inbox-scan-orchestration`: The end-to-end data path — the app enqueues a scan, the persistent
  worker runs it, results bridge into the app's candidate review queue, and scan status/reads flow
  back to the app.

### Modified Capabilities
<!-- None: openspec/specs/ is currently empty; there are no prior spec-level requirements to amend. -->

## Impact

- **Worker (`worker/`)**: `src/worker.ts` (make autonomous the live loop), a real inbox read
  executor (replace the scan-window stub), DB-backed `ReconcileReaders`, and an outcomes→candidates
  bridge. New/changed env: promote `AGENT_MODE=autonomous`, provider OAuth access, app-DB access.
- **Edge function (`supabase/functions/email-scan/index.ts`)**: reduced to enqueue-a-scan +
  status/read; `runAgenticDiscovery` and the legacy per-message extractor branch removed.
- **Shared modules (`supabase/functions/_shared/`)**: delete/retire `discovery-classifier`,
  `discovery-routing`, `discovery-verify`, `agentic-reasoner`, and the keyword-scorer helpers in
  `email-discovery.ts`. Keep OAuth/crypto/provider fetch + the candidate/review plumbing.
- **Database**: the worker's `scan_jobs` / `scan_outcomes` queue (`worker/migrations/`) becomes
  load-bearing; a bridge writes into the app's `subscription_candidates`. No change to the iOS
  review UI contract.
- **iOS app (`Renewa/`)**: no UI change; it keeps calling `POST /functions/v1/email-scan` and
  reading `subscription_candidates`. Only the server behind that endpoint changes.
- **Ops**: the persistent worker must be deployed with DB + OAuth + DeepSeek credentials; a
  real-inbox smoke test gates the cutover (the eval used the scan-window executor, not live Gmail).
