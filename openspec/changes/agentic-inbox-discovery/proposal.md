## Why

The current inbox discovery pipeline reasons **one email at a time** and rejects
subscriptions on strict AND-gates, so it silently misses real, paid subscriptions
whose evidence is spread across several emails (e.g. a welcome email + a receipt that
never literally says "monthly"). A user who genuinely subscribed to Anthropic saw
"needs more evidence / no action" because the receipt's missing billing-cycle word
disqualified it at `isPaidRecurringEvent`, and per-message extraction had no sibling
email to supply the cycle. These are recall/completeness failures, not precision
failures. We want the discovery step to behave like an **agent** — assemble all the
evidence about a merchant, actively go find more when it is under-confident, and turn
"I'm missing one field" into a single question instead of a silent drop — while keeping
the safety invariants that already work (a human confirms every add; no invented
amounts; email content is untrusted data, never instructions).

## What Changes

- **Reasoning unit shifts from email → merchant.** Candidate emails are grouped into a
  per-merchant evidence bundle, and the pipeline reasons over the whole bundle so fields
  missing from one email can be supplied by its siblings.
- **New tier-1 wide classifier** (cheap/fast model) scores **all** fetched messages for
  subscription-relevance and merchant, replacing the keyword-only `isLikelyBillingCandidate`
  cutoff as the recall gate. **BREAKING** (internal): the keyword prefilter is no longer
  the sole gate into extraction.
- **New tier-2 agentic reasoning loop** (DeepSeek) runs per merchant. Within a strict
  budget it can call read-only, connection-scoped tools — `search_inbox(query)`,
  `fetch(message_id)`, `get_more(sender)` — to gather more evidence, then emits a
  structured assessment with confidence, missing fields, and grounded evidence refs.
- **Extract→verify pass**: a grounding check rejects or downgrades any asserted field
  not supported by the evidence, so relaxing "never infer" does not cost precision.
- **Confidence-ladder routing** on two axes (existence × completeness): high-existence +
  complete → present a candidate; high-existence + incomplete → **ask one clarification**
  (reusing the existing `billing_cycle_check` flow); low-existence → watch/ignore.
  This is the fix for the Anthropic class of miss.
- **Persist near-misses / abstain reasons** (currently computed and thrown away) so
  "we saw this merchant but couldn't confirm it" becomes visible and debuggable.
- **A hard guardrail envelope** around the agentic loop: per-merchant iteration/fetch/token
  budgets, a per-run global budget and merchant cap that fit the edge-function execution
  limits, read-only tools scoped to the current connection and merchant, reinforced
  untrusted-data discipline, and an unchanged human-confirmation gate (the loop never
  tracks anything on its own).

Out of scope for this change (tracked as follow-ups): the cross-scan evidence ledger and
the golden-set evaluation harness.

## Capabilities

### New Capabilities
- `discovery-candidate-classifier`: Tier-1 wide, cheap classification of all fetched
  messages into subscription-relevance + merchant guess + rank, replacing the keyword
  prefilter as the recall gate and feeding merchant grouping.
- `agentic-merchant-reasoner`: Tier-2 per-merchant bounded agentic loop with read-only,
  connection-scoped inbox tools and a hard budget/guardrail envelope, emitting a
  structured, evidence-grounded merchant assessment.
- `discovery-decision-routing`: Extract→verify grounding, two-axis confidence-ladder
  routing (present / ask-clarification / watch), and persistence of near-misses and
  abstain reasons — all preserving the human-confirmation gate.

### Modified Capabilities
<!-- No baseline specs exist in openspec/specs/; all behavior here is introduced as new capabilities. -->

## Impact

- **Edge functions**: `supabase/functions/email-scan/index.ts` (orchestration, run/budget
  accounting, routing) and `supabase/functions/_shared/email-discovery.ts` (prefilter →
  classifier, per-message extract → per-merchant reasoner, new verify + ladder). The
  deterministic `reconcileMerchantLifecycle` state machine is preserved but fed by the new
  reasoner output.
- **Models / secrets**: introduces a second, cheaper/faster classifier model behind
  OpenAI-compatible config (new hosted secret, e.g. `CLASSIFIER_API_KEY` / `CLASSIFIER_MODEL`
  / `CLASSIFIER_BASE_URL`); tier-2 continues on `DEEPSEEK_*`.
- **Database**: a new table/columns to persist near-misses / abstain reasons and per-run
  agent-budget accounting (migration). No change to the human-facing `subscriptions` or
  confirmation contract.
- **Cost/latency**: fewer expensive calls per scan (one reasoner per *merchant* instead of
  one per *email*), offset by the classifier pass over all mail and by loop tool calls —
  bounded by the per-run budget.
- **Security**: larger prompt-injection surface (an autonomous loop over untrusted email
  choosing what to fetch). Mitigated by read-only, connection/merchant-scoped tools with
  validated arguments, hard budgets, and the unchanged human gate — a compromised loop can
  at worst waste budget or propose a candidate a human rejects.
- **iOS app**: no new decode contract required for the core spine; incomplete-but-strong
  merchants surface through the existing clarification UI. Near-miss surfacing to the app is
  optional and can follow.
