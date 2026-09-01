## 1. Terminalize the analysis loop (D1, D2) — the unshippable bit; do first

- [x] 1.1 Pure `isPermanentProviderError(message)` helper in `worker/src/managed/provider-errors.ts`
      → true for 402/"insufficient balance", 401/"invalid api key"/auth-fail; false for timeouts/5xx/429.
      Unit tests (`worker/test/provider-errors.test.ts`) cover each case.
- [x] 1.2 `worker/src/trigger/analyze-inbox-page.ts`: on a permanent provider error, `failJob` +
      `completeExecution(..., "failed")` (same shape as cancellation) instead of retryable; and the DB
      `complete_inbox_agent_execution` caps `retryable` → `failed` at `dispatch_attempt >= 3`, then fails
      the page and finalizes the run.
- [x] 1.3 Cap is `dispatch_attempt >= 3` — reuses the existing reaper convention (fixed, not env; matches
      `recover_expired_inbox_agent_executions`). Permanent errors fail immediately regardless of count.
- [x] 1.4 Worker tests green (107 pass) incl. the permanent/transient classifier; `tsc --noEmit` clean.

## 2. Reaper backstop for retryable executions (D3)

- [x] 2.1 Migration `202608310003`: `recover_exhausted_inbox_agent_retries()` fails `retryable`
      executions with `dispatch_attempt >= 3`, fails their scan job, and finalizes the run; scheduled
      every minute via pg_cron.
- [x] 2.2 DB assertion (rolled back): cap coercion in `complete_inbox_agent_execution`, under-cap stays
      retryable, and the backstop fails a spent retryable + finalizes — all green against the live schema;
      committed as `supabase/tests/terminalize_inbox_analysis.sql`.

## 3. User-safe error messages (D4)

- [x] 3.1 Pure `userFacingScanError` / `categorizeScanError` in `supabase/functions/_shared/scan-errors.ts`
      → analysis-unavailable / inbox-authorization / worker-unavailable / generic. Unit tests incl. raw
      "Insufficient Balance", "Bad Request", "Authentication Fails … api key"; a test asserts no raw text
      ever leaks.
- [x] 3.2 Applied where the status `errors[]` is assembled (`email-scan/index.ts`): each non-empty
      internal reason is mapped through `userFacingScanError`; empty when there are no errors. Internal
      `error_message` stays in the DB for diagnostics. `deno check` clean; 88 edge tests pass.

## 4. Progress counts distinct pages (D6) — DEFERRED (design snag)

- [ ] 4.1 BLOCKED: `email_scan_batch_progress` SUMs `message_count` across `scan_jobs`, and `scan_jobs`
      has **no page-identity column**, so there is no clean key to dedupe retried pages. The inflation's
      real source is the orchestrator inserting a duplicate `scan_jobs` row per retry; Group 1's
      terminalization already removes the 30×-loop pathology that produced "3000". A correct fix needs a
      page-identity key on `scan_jobs` (or fixing the orchestrator re-insert) — larger than a progress-RPC
      tweak. Recommend splitting to its own change.
- [ ] 4.2 (blocked with 4.1)

## 5. App: distinct failed state + retry (D5)

- [x] 5.1 Added `DashboardState.scanFailed` to `EmailDiscoveryPresentationState`, derived after the
      reconnect check: a `failed`/`partial`/`errorCount>0` aggregate with no connection-health problem →
      `scanFailed` (a real reconnect issue stays `needsAttention`). Tests updated (partial/failed →
      scanFailed) + a new test asserts a reconnect-required connection stays needsAttention.
- [x] 5.2 `EmailScanView` renders `scanFailed` across every dashboardState switch (icon, coral tint,
      title "Couldn’t finish the scan", message from the now-user-safe `errors.first`); the existing
      action already resolves to **Try again** → new scan when there's no attention connection. Build +
      tests green (`** TEST BUILD SUCCEEDED **`, `** TEST EXECUTE SUCCEEDED **`).
- [ ] 5.3 (Optional open question, not done) a `partial` scan shows found candidates plus a non-blocking
      error banner — deferred; current behavior surfaces the failure state.

## 6. Verification and release

- [ ] 6.1 Deploy worker (Trigger) + apply migration + deploy edge; ship the app build.
- [ ] 6.2 With an unfunded/invalid LLM key: start a scan → it fails **fast** with a friendly
      "analysis unavailable" message and a Retry, no minute-by-minute loop, progress not inflated.
- [ ] 6.3 With a healthy key: a scan completes and candidates land (regression check).
- [ ] 6.4 Confirm no raw provider string ("Insufficient Balance"/"Bad Request") is ever shown to a user.
