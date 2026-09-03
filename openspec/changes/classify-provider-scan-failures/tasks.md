## 1. Classify the failure where the status is known

- [x] 1.1 In `supabase/functions/email-scan/index.ts`, give `providerFetch` (2573) a classified
      error: map `401`/`403` to authorization, `429` to rate limited, `5xx` to provider unavailable,
      anything else failing to generic. Carry the class on the thrown error rather than encoding it
      in prose. Never include the provider's response body.
- [x] 1.2 Update the nine `providerFetch` call sites (2195-2481) so the message they supply describes
      *which request* failed, not *why* — the why now comes from the status. No mailbox call site
      should hardcode "Reconnect your inbox" any more.
- [x] 1.3 Comment the choke point: the status used to be discarded here, which made a `429`
      indistinguishable from a revoked token and sent users to re-authorize healthy inboxes.

## 2. Carry the class through to the user

- [x] 2.1 In `supabase/functions/_shared/scan-errors.ts`, add `provider-rate-limited` and
      `provider-unavailable` categories with copy that names the real problem and does not mention
      reconnecting.
- [x] 2.2 Make `categorizeScanError` prefer an explicit class when the error carries one, falling
      back to pattern matching only for errors that do not. The current circularity — matching on
      "reconnect", a word only our own code writes — must be gone.
- [x] 2.3 Narrow the `inbox-authorization` pattern so it no longer absorbs rate-limit or outage text,
      while still matching genuine authorization failures.
- [x] 2.4 Ensure the failure recorded on the scan job identifies its class, so a stored failure can
      be diagnosed later without re-running the scan.
- [x] 2.5 Check that `processUserJobs`'s monitoring-health regex (738-750) no longer flips a
      connection to `reconnect_required` for a non-authorization failure.

## 3. Retry what retrying can fix

- [x] 3.1 In `processManagedConnection` (620), retry a retryable failure instead of failing the run:
      re-queue with `attempts + 1 < 3` and `available_at = now + (attempts + 1) * 2s`, matching the
      legacy `processUserJobs` policy rather than inventing a second one for the same table.
- [x] 3.1a Make the claim honour `available_at`, and report `has_next_page: true` with
      `retry_after_ms` when a queued page is still waiting out its backoff — reporting `false` would
      strand the page and stall the run.
- [x] 3.1b Carry `retryAfterMs` through the managed step contract and have `orchestrateManagedScan`
      wait it out with Trigger's durable `wait.for`. Without this the backoff is decorative: the
      loop has no other delay (see design).
- [x] 3.2 Fail an authorization failure immediately without consuming attempts — retrying a revoked
      token only delays the one message that helps.
- [x] 3.3 Leave `finalizeScanRunIfDrained` untouched, and confirm a page is always either completed,
      queued with a future `available_at`, or failed — so no run can hang, per
      `surface-inbox-scan-errors`.
- [x] 3.4 Comment why the managed path is gaining this: the legacy path always had it, the managed
      path silently did not, and that divergence turned one throttled page into a discarded scan.

## 4. Tests

- [x] 4.1 In `supabase/functions/_shared/scan-errors.test.ts`, cover each status → category mapping,
      and assert that a rate-limit failure never produces reconnect copy.
- [x] 4.2 Assert the reverse direction too: a genuine `401` still produces the reconnect message, so
      narrowing the pattern did not break the case it exists for.
- [x] 4.3 Assert no provider response body can reach a user-facing message.
- [x] 4.4 Test the retry decision as a pure function: rate-limited and unavailable are retryable,
      authorization is not, and attempts are exhausted after the third.
- [x] 4.5 Test that backoff grows with attempts.

## 4b. Classify from the provider's reason, not the status alone

- [x] 4b.1 Gmail reports per-user quota as **403**, not 429, so the status alone classified a
      throttled scan as a revoked credential — and authorization is not retryable, so the retry never
      engaged for the one failure it existed for. Observed 2026-09-03: pages 1-3 completed on a token
      minted six seconds earlier, page 4 returned 403, run failed.
- [x] 4b.2 Read the error body on the failure path only and extract the machine reason
      (`error.errors[].reason`, `error.status`, Graph's `error.code`). Accept identifier-shaped
      tokens only, so provider prose cannot ride along.
- [x] 4b.3 Map quota reasons to rate-limited and auth reasons to authorization; fall back to the
      status when the reason is absent or unrecognized. A bare 403 stays authorization.
- [x] 4b.4 Record the status and reason in the stored error, so the next failure is diagnosed rather
      than inferred.
- [x] 4b.5 Tests for both directions, real Google and Graph body shapes, and the prose rejection.

## 5. Verify

- [x] 5.1 `deno check` the edge function and run both edge test suites.
- [ ] 5.2 Deploy the edge function; the worker goes live through the running `trigger:dev`
      session. Confirm no migration and no iOS build.
- [ ] 5.3 Run a real scan and confirm it completes. If a page hits a `429`, confirm it re-queues and
      the run still finishes rather than failing.
- [x] 5.4 Re-read the failed run from 2026-09-03 (`9b766187`) as the motivating case, and confirm the
      new classification would have described it accurately.
