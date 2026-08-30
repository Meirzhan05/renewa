## Why

Genuinely-detected subscriptions are auto-hidden before a person ever sees them, which is the root of
the long-standing "my scan finds nothing" complaint. On a real scan the agent proposed ChatGPT Plus,
Claude Pro, and Firebase — and every one was silently set to `review_status = 'ignored'` with the
system reason "Current renewal evidence is unavailable for this merchant," so `pending_count` was 0 and
the review queue stayed empty.

The mechanism: `reconcilePendingCandidates` runs on **every status poll** and auto-resolves any pending
"add" candidate whose merchant lifecycle is not exactly `current` (`email-scan/index.ts:1424`). A
merchant is only `current` when it has a paid-recurring event (amount + valid currency + billing cycle)
whose renewal is in the future. That rule silently discards the most common first-scan cases:

- **Incomplete extraction** — ChatGPT/Firebase were detected with no amount/cycle, so they can never be
  `current`.
- **Historical receipts** — an existing mailbox's last receipt often has a renewal already in the past,
  so the merchant reads `uncertain`.
- **A mid-scan race** — reconcile runs while the scan is still writing events, so a candidate can be
  judged (and hidden) before its own future-renewal evidence lands (Claude's August receipt, renewal
  2026-09-22, was ignored despite qualifying).

## What Changes

- Discovery candidates SHALL only be auto-resolved (hidden) when the merchant is **suppressed** or has
  **explicitly ended** (a cancellation). An `uncertain` lifecycle SHALL NOT hide a first-time discovery —
  it SHALL remain pending for the person to review, since "we can't confirm it's current" is exactly the
  judgment the review queue exists for.
- Reconciliation SHALL NOT resolve candidates that belong to a **still-active scan run**; a run's
  candidates become eligible for lifecycle reconciliation only once the run is terminal. This removes
  the mid-scan race.
- Uncertain-but-surfaced candidates SHOULD carry a signal that their "current" status is unconfirmed, so
  the review card can label them (non-breaking; optional presentation).
- No change to the `email-scan` request/response **contract**; the existing status/candidate fields are
  reused.

## Capabilities

### New Capabilities
- `discovery-review-surfacing`: Defines which discovered subscriptions reach the review queue vs. are
  auto-resolved, and when lifecycle reconciliation may run relative to an in-progress scan.

### Modified Capabilities
<!-- none: openspec/specs is empty; the lifecycle reconciliation lives in the in-progress
     autonomous/agentic discovery changes this builds on -->

## Impact

- **Edge:** `supabase/functions/email-scan/index.ts` — `reconcilePendingCandidates` (the
  `lifecycle.state !== "current"` rule at ~`:1424`, and the every-poll call at ~`:1042`); add an
  active-run guard. Pure-testable logic where possible. Requires `deno check` + edge redeploy.
- **Behavior:** first-scan discoveries (ChatGPT/Claude/etc.) reach the review queue instead of being
  auto-ignored; explicitly-ended and suppressed merchants stay hidden as before.
- **Data (optional):** a one-off re-open of recently system-ignored `uncertain` discoveries so existing
  users (including this test account) immediately see what was hidden.
- **No destructive migration.**
- **Out of scope:** improving extraction so amount/currency/cycle are captured (ChatGPT came back with
  none) — tracked separately; and any change to the lifecycle math itself.
