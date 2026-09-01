## Why

A scan that fails mid-analysis is invisible to the user. On 2026-09-01 the DeepSeek LLM ran out of
credits; every `analyze-inbox-page` call returned "Insufficient Balance", but the worker treats **any**
analysis error as `retryable` with no attempt cap (`analyze-inbox-page.ts:48`), so the dispatcher
(`reserve_inbox_agent_executions`) re-leased the same page every minute for **13+ hours**. The run
never reached a terminal state, so the app kept showing "scanning…" — and because progress SUMs each
retried page's `message_count`, it displayed **"3000 emails checked"** for what was really ~100 emails
re-counted 30 times. No error, no candidates, no way for a user to know the scan was dead. A production
user cannot be left in this state.

Two related gaps make it worse: raw provider strings ("Insufficient Balance", "Bad Request") flow
straight into the status `errors[]` (`email-scan/index.ts:1354`) and are rendered verbatim in the app
(`EmailScanView.swift:1014`); and the only failure surface in the app is the connection-scoped
`needsAttention` state, so an analysis failure that isn't a connection problem has no clean home.

## What Changes

- **Analysis failures SHALL become terminal.** `analyze-inbox-page` SHALL fail an execution (not
  retry) once it has exhausted a bounded number of attempts, and SHALL fail fast on a **permanent**
  provider error (e.g. billing/402 "insufficient balance", auth/401 invalid key) rather than retrying
  it. A failed execution fails its page and finalizes the run as `failed`. A reaper clause SHALL fail
  `retryable` executions past the attempt cap as a backstop.
- **User-facing errors SHALL be safe, categorized messages** — never raw provider text. Internal
  errors map to categories: analysis-unavailable ("We couldn't finish scanning — please try again
  later"), inbox-auth ("Reconnect your inbox"), generic worker failure. Applied before a message
  reaches the status `errors[]`.
- **The app SHALL surface a distinct "scan couldn't finish" state** (separate from connection
  `needsAttention`) with the friendly reason and a **Retry**, so a failed scan is unmistakable.
- **Progress SHALL count distinct emails, not retried duplicates** — the "checked" total must not
  inflate when a page is retried.

## Capabilities

### New Capabilities
- `inbox-scan-error-visibility`: Guarantees a scan that cannot complete reaches a terminal `failed`
  state with a user-safe reason within a bounded time, is surfaced distinctly in the app with a retry,
  and never shows raw provider errors or inflated progress.

### Modified Capabilities
<!-- none: openspec/specs/ is empty. This extends the terminal-and-visible philosophy of the in-flight
     `surface-stalled-inbox-scans` change from the dispatch stage to the analysis stage + presentation. -->

## Impact

- **Worker**: `worker/src/trigger/analyze-inbox-page.ts` (attempt cap + permanent-error classification),
  a small error-classifier helper, and possibly `completeExecution` states.
- **Migration**: extend the reaper to fail `retryable` executions with `dispatch_attempt >= N` (backstop),
  and finalize the run; align with `recover_stalled_inbox_scan_runs` / `recover_expired_inbox_agent_executions`.
- **Edge**: `email-scan/index.ts` — map run/job error messages to user-safe categories before building
  the status `errors[]`; ensure the progress RPC (`email_scan_batch_progress`) counts a page once even
  when retried.
- **App**: `Renewa/EmailScanView.swift` + `EmailDiscoveryPresentationState.swift` — a distinct failed
  state with a retry action; render the categorized message, not `errors.first` raw.
- **Out of scope**: improving what the two-tier funnel proposes (funnel quality), and provider billing
  itself (operational).
