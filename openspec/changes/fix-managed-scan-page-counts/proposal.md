## Why

A historical inbox scan is split across many mailbox pages (the verified run walked 18 pages / ~1,800
messages over ~52 minutes). The app-visible "emails checked" counter is written per page as an
**overwrite** of a single run-level column, so it sits frozen at one page's worth — that run reported
`messages_scanned = 100` for its entire duration. Now that run completion is correct (a run stays
`running` until its last page drains), a counter stuck at "100 emails checked" for the whole scan is
the thing that now reads as *stopped*: it hides real progress and makes a healthy long scan look
stalled. The fix is to make progress counts cumulative across a run's pages.

## What Changes

- App-visible scan progress (**messages checked**, **likely-billing messages**, **changes detected**)
  SHALL reflect the **cumulative total across all mailbox pages of a run**, not the most recently
  processed page, and SHALL only ever grow as pages complete.
- The run's scanned total SHALL be **derived from the per-page ledger** (summed over the run's page
  jobs) rather than by overwriting a single `email_scan_runs` counter column on every page. This makes
  the count **idempotent under task retries** — re-processing a page cannot double-count or reset it.
- The `email-scan` status endpoint's aggregate `scanned` / `candidate_messages` / `detected` fields,
  and the per-run values in `runs[]`, SHALL be computed from this ledger so a multi-page scan shows
  monotonically increasing progress.
- No change to the `POST /functions/v1/email-scan` request/response **contract** — the iOS app, its
  poll loop, and its models stay as-is. This is a correctness fix to how existing fields are computed.
  No iOS change is required.

## Capabilities

### New Capabilities
- `inbox-scan-progress-counts`: Defines cumulative, retry-safe progress semantics (messages checked,
  likely-billing messages, changes detected) for a scan whose mailbox work spans multiple pages.

### Modified Capabilities
<!-- none: openspec/specs is empty; the adjacent paginated-inbox-scan-lifecycle capability is still an
     in-progress change and covers completion, not progress counters -->

## Impact

- **Edge Function:** `supabase/functions/email-scan/index.ts` — the status derivation
  (`scanned: sum(runs, "messages_scanned")` and siblings ~`:1213-1216`, plus the per-run `runs[]`
  mapping ~`:1231-1233`) must aggregate the per-page ledger for each run; the per-page overwrite of
  `email_scan_runs.messages_scanned` / `candidate_messages` at fetch time (~`:807-811`) becomes a
  cache/no-op rather than the source of truth. Requires `deno check` + edge redeploy (no local `deno`).
- **Ledger source:** each mailbox page already persists its message window
  (`scan_jobs.raw_messages`, one row per worker page). The design picks between summing that directly
  vs. a small denormalized per-page count column.
- **Behavior:** after the fix, "N emails checked" climbs page by page during a long scan instead of
  reading a flat "100", so an in-progress multi-page scan is visibly alive.
- **No destructive migration.** Any new column is additive and nullable; the derivation can also be
  pure-read with no schema change. `messages_scanned` semantics are corrected, not removed.
- **Out of scope:** scan throughput / parallelizing page analysis (tracked separately as the
  managed-scan throughput change) and the already-shipped run-completion fix.
