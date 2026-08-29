## Why

After the inbox-scan cutover, a scan the user starts in the app reports **"completed — nothing to
review"** even when discovery has not actually run. The status endpoint derives the app-visible
scan status from the edge function's own connection queue (`email_scan_jobs`), which is marked
`completed` the instant the mailbox window is handed off to the worker — well before (or entirely
independent of) the worker running the funnel and writing candidates. The app stops polling the
moment it sees that false "completed", so results the worker produces later are never shown. If the
worker is not running at all, the run silently looks finished with zero candidates.

## What Changes

- The `email-scan` status endpoint SHALL derive the app-visible aggregate scan status from the
  **worker's actual progress** (the `email_scan_runs` lifecycle the worker finalizes, and/or the
  worker `scan_jobs` queue state), **not** from the edge's `email_scan_jobs` enqueue queue. A run
  handed to the worker but not yet finalized SHALL report as still in progress so the app keeps
  polling until candidates exist.
- The status endpoint SHALL treat a handed-off-but-unfinalized run as **stale/failed after a bounded
  time** (worker-down timeout), so a scan surfaces an honest "couldn't finish" state instead of a
  false "nothing found" when no worker drains `scan_jobs`.
- No change to the `POST /functions/v1/email-scan` request/response **contract** — the iOS app,
  its poll loop, and its models stay as-is. This is a correctness fix to how the existing
  `status` / `stage` fields are computed. (A small optional app-side hardening — treating the
  `reasoning` stage as active — is in scope only as defense in depth, not the primary fix.)

## Capabilities

### New Capabilities
<!-- none -->

### Modified Capabilities
- `inbox-scan-orchestration`: The "Agent proposals bridge into the app review queue" →
  "Scan status is readable" requirement is corrected. "The app can observe the run progressing and
  completing" SHALL mean completion as determined by the **worker finalizing the run**, not by the
  edge function finishing its enqueue step. Adds a bounded worker-completion-timeout requirement so a
  never-processed job resolves to a failed/partial state rather than a false completed-empty state.

## Impact

- **Code:** `supabase/functions/email-scan/index.ts` — `scanStatus` (aggregate `status`/`stage`
  derivation, currently from `email_scan_jobs`; the per-run `runs[]` mapping that prefers
  `job.status`), plus a timeout/staleness helper. Requires `deno check` + edge redeploy (no local
  `deno`).
- **Behavior:** After the fix, a started scan stays "scanning" in the app until the worker finalizes
  the run and its candidates are queryable; the app's existing poll loop then renders the review
  queue. Requires the worker to actually be running against the same Postgres — this change makes a
  missing worker *visible* (timeout → failed) instead of masking it as "nothing found".
- **No DB migration.** Relies on columns already present: `email_scan_runs.status/stage/…`,
  `scan_jobs.status`, `subscription_candidates.review_status`.
- **No iOS change required** for the fix; the primary change is server-side in the edge function.
