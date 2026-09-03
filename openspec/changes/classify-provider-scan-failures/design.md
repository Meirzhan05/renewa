## Context

`providerFetch` is the single choke point for every Gmail and Microsoft Graph request the scan makes
— nine call sites between `index.ts:2195` and `2481`. It takes a fixed failure message per call site
and throws it on any non-OK response:

```ts
async function providerFetch(url, accessToken, failureMessage) {
  const response = await fetch(url, { headers: { Authorization: `Bearer ${accessToken}` } });
  if (!response.ok) throw new Error(failureMessage);   // status discarded here
  return response;
}
```

The mailbox call sites pass `"Gmail could not be read. Reconnect your inbox."`, so every failure of
those requests reads as an auth problem. That text then flows into `categorizeScanError`, whose
`inbox-authorization` pattern is `/bad\s+request|reconnect|…|token/i` — it matches the word
"reconnect" that the previous stage just wrote. The classification is circular: the system diagnoses
the failure from its own guess about the failure.

Downstream, `processUserJobs` sets monitoring health from the same text
(`/reconnect|access expired|invalid.*token|unauthori[sz]ed/i` → `reconnect_required`), so a rate limit
also degrades the stored connection health.

Separately, the two page-processing paths diverged. The legacy path retries; the managed path — the
one every scan now uses — does not:

```
processUserJobs (legacy, index.ts:738)      processManagedConnection (managed, index.ts:620)
  retryable = job.attempts + 1 < 3            catch → status:"failed", finalize, rethrow
  status: retryable ? "queued" : "failed"     (no attempts check, no backoff)
  available_at: now + (attempts+1) * 2s
```

Observed consequence: seven pages read, page 8 failed on attempt 1, whole run failed, user told to
reconnect a sixty-second-old healthy connection.

## Goals / Non-Goals

**Goals:**

- Classify a provider failure by what the provider actually said, and keep that classification intact
  all the way to the user-facing message.
- Reserve "reconnect your inbox" for failures reconnecting can fix.
- Give the managed page path the retry-with-backoff the legacy path already has, for failures where
  retrying is meaningful.
- Preserve the anti-exfiltration boundary: no provider body text reaches a user.

**Non-Goals:**

- Reworking `categorizeScanError`'s existing categories or the Inbox failure UI. New categories are
  added; the rendering path is untouched.
- Unifying the legacy and managed page paths. They should converge eventually; doing it here would
  widen a bug fix into a refactor.
- Provider-specific backoff honouring `Retry-After`. Worth doing, but it needs its own thought about
  how long a scan may stall; noted as an open question.
- Any change to how pages are reserved or dispatched.

## Decisions

### Classify at the throw site, carry the class on the error

`providerFetch` throws an error carrying a `category` alongside its message, rather than a bare
string. The class is decided where the status is still in hand, and every later consumer reads the
field instead of re-deriving it from words.

*Alternative rejected — keep throwing strings and widen the regexes in `categorizeScanError`:* the
regexes are the problem, not their coverage. Text written by an earlier stage is being pattern-matched
by a later one, so any fix is one wording change away from breaking. It is also what produced the
current bug: `inbox-authorization` matches "reconnect", a word only our own code wrote.

*Alternative rejected — pass a category per call site:* the call site does not know what the provider
will do. It knows which request it is making, not why it failed.

### The provider's reason outranks the status

Shipped wrong first time, and worth recording why. `401`/`403` were both mapped to authorization on
the reasoning that they are the auth statuses. But **Gmail reports per-user quota exhaustion as 403**
with a `reason` of `userRateLimitExceeded`, not as 429. So the single most likely failure during a
long scan was classified as a revoked credential — and since authorization is deliberately not
retryable, the retry built in this same change never engaged for it.

Observed on 2026-09-03 after deploying: pages 1-3 completed on a token minted six seconds earlier and
valid for another hour, page 4 returned 403, and the run failed telling the user to reconnect.

So the failure path now reads the body for its machine reason and classifies from that, falling back
to the status when there is none. Only identifier-shaped tokens are accepted (`^[A-Za-z_]+$`, bounded
length), so a provider's free text cannot ride along — the anti-exfiltration boundary holds, and the
user still sees fixed copy per category. A bare 403 with no reason stays authorization, which is the
conservative reading.

The lesson generalises: a status code is a weaker signal than the provider's own error taxonomy, and
mapping statuses without checking how each provider actually reports quota is guessing.

### Map status ranges, not individual codes

`401`/`403` → authorization. `429` → rate limited. `5xx` → provider unavailable. Everything else →
generic provider failure. Deliberately coarse: the point is to stop conflating "your credentials are
gone" with "try again shortly", not to enumerate provider error codes.

A `404` stays generic rather than being special-cased. It can mean a deleted message, which is a real
scenario, but it is not the failure this change exists to fix and guessing at it would add a class
nobody can act on.

### Retry only what retrying can fix

Retryability follows from the class, not from an attempt counter alone: rate-limited and
provider-unavailable are retryable, authorization is not, generic is. Retrying a revoked token three
times delays the only message that would help the user by several seconds and makes the log harder to
read.

The managed path reuses the legacy path's shape — `attempts + 1 < 3`, `available_at = now +
(attempts + 1) * 2s` — so the two behave the same way rather than inventing a second retry policy for
the same table.

**The backoff only works if someone waits it out, which forced this change into the worker.** The
legacy path gets its delay for free: `processUserJobs` filters `.lte("available_at", now)` and is
driven by repeated status polls, so the poll cadence *is* the backoff. The managed path is driven by
`orchestrateManagedScan`, a `for(;;)` loop with no sleep, and its claim had no `available_at` filter
at all — so re-queueing with a future `available_at` would have been decorative: the loop would
re-take the same page instantly, burn all three attempts in milliseconds, and fail anyway, having
made three rapid requests to a provider that had just asked us to slow down. Strictly worse than not
retrying.

So the claim now honours `available_at`, the Edge Function reports `retry_after_ms`, and the
orchestrator waits via Trigger's `wait.for` — durable, so a backoff survives the worker restarting
mid-scan. When no page is claimable but queued pages remain, the Edge Function reports
`has_next_page: true` with the delay rather than `false`; reporting `false` would strand the page and
stall the run.

*Alternative rejected — retry every failure class uniformly:* simpler, but it means a user whose
Gmail authorization was revoked waits through three attempts before being told, and the run's error
history fills with identical auth failures.

### Do not touch the run's finalization

A retried page goes back to `queued` and the run stays `running`; an exhausted page fails through the
existing path. `finalizeScanRunIfDrained` is unchanged, so the "no run hangs forever" property that
`surface-inbox-scan-errors` established still holds — a page is always either completed, queued with
a future `available_at`, or failed.

## Risks / Trade-offs

- **A retried page extends a scan that would previously have failed fast** → Bounded by the existing
  3-attempt limit and 2s-per-attempt backoff, so at most a few extra seconds per page. Preferable to
  discarding seven pages of completed work.
- **Rate limiting may not clear within the backoff** → Then the page exhausts its attempts and fails
  as it does today, but with an accurate message. Honouring `Retry-After` would do better and is left
  as an open question rather than guessed at.
- **New categories must reach the Inbox UI intact** → The screen renders `userFacingScanError`'s
  output, so new categories flow through without a client change. Verify the copy reads sensibly in
  the failed-scan state before deploying.
- **Narrowing `inbox-authorization`'s pattern could let a real auth failure fall through to generic**
  → The pattern still matches genuine auth text; what is removed is its ability to claim failures
  that a status code has already classified otherwise. Covered by tests on both directions.
- **The two page paths still differ** → This change makes their retry behaviour match but leaves them
  as separate code. That divergence caused this bug and will cause another; worth its own change.

## Migration Plan

1. Add the classified error and status mapping in `providerFetch`; update call sites to stop passing
   reconnect-flavoured text for non-auth failures.
2. Add categories and messages in `scan-errors.ts`; narrow `inbox-authorization` so it no longer
   absorbs them.
3. Add retry-with-backoff to `processManagedConnection`, gated on retryability.
4. `deno check` and the edge test suites.
5. Deploy the edge function, and the worker (a `trigger:dev` session picks it up live). No
   migration, no iOS build.
6. Verify with a real scan; a page that hits a `429` should re-queue and the run should complete.
7. Rollback: revert the edge function. Nothing persists that a rollback would strand — retried jobs
   are ordinary queued rows.

## Open Questions

- Should backoff honour the provider's `Retry-After` header when present? Gmail sends it on some
  `429`s. It would make the retry accurate, but a long value could stall a scan well past what a user
  waiting on the screen expects, so it needs a cap decided deliberately.
- Should a page that exhausts retries on rate limiting leave the run `partial` rather than `failed`,
  given earlier pages produced real results? The current model has no partial-success state for a
  single connection's pages, and inventing one is larger than this change.
- Should `404` be treated as a skippable message rather than a page failure? Needs evidence that it
  actually occurs before adding a class for it.
