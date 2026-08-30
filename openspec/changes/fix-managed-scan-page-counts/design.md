## Context

A scan run is split across many mailbox pages (verified: one run walked 18 worker pages / 1,800
messages over ~52 min). Today every page **overwrites** run-level counters:

- Edge `processConnectionJob` (`email-scan/index.ts:807-811`) sets `messages_scanned` /
  `candidate_messages` to *this page's* window length on each page.
- The status endpoint (`:1213-1216`) then reports `scanned: sum(runs, "messages_scanned")` — a sum
  across **runs** (connections), not **pages**. For a single inbox that is one run, so the app shows
  the last page's count.

Measured on the 18-page run: run columns read `messages_scanned=100`, `candidate_messages=100`,
`events_detected=0`, while the truth is 1,800 messages scanned and 6 detected events. The per-page
ledger is intact and reliable: `scan_jobs` holds one row per page, `SUM(jsonb_array_length(raw_messages)) = 1800`,
no empty pages. The run-completion fix already shipped, so a run correctly stays `running` across all
pages — which is exactly why a counter frozen at "100" now reads as "stopped."

## Goals / Non-Goals

**Goals:**
- "Messages checked", "likely-billing emails", and "changes detected" grow cumulatively across a run's
  pages and are correct at completion.
- Counting is idempotent under trigger.dev task retries / page re-claims.
- No iOS client change; no destructive migration.

**Non-Goals:**
- Scan throughput / parallelizing page analysis (separate managed-scan-throughput change).
- Any change to run completion / status classification (already shipped and verified).
- Redefining what counts as a "connection" or changing the batch/run model.

## Decisions

### D1 — Derive progress from the per-page ledger, not a per-page overwrite
The single source of truth for progress becomes the set of page rows for a run, aggregated at read
time in the status endpoint. Run-level columns (`email_scan_runs.messages_scanned` etc.) are demoted
to a best-effort denormalized cache (or left unwritten); the app-visible number comes from the
aggregate. *Why:* a per-page overwrite can never represent a multi-page total, and read-time
aggregation is always correct even if an individual write is missed or replayed.
*Alternative rejected:* write-time `+=` accumulation on the run column — not idempotent; a task retry
double-counts and a reset zeroes real progress.

### D2 — Ledger unit = a nullable `message_count` on the page row
Add `scan_jobs.message_count int` (nullable), set at enqueue by the edge from `providerBatch.metadata.length`
(the value it already overwrites onto the run). The status endpoint sums
`coalesce(message_count, jsonb_array_length(raw_messages))` per run. *Why:* summing a small int column
over ≤30 rows is cheap and never transfers the message payloads on every poll; the `jsonb_array_length`
`coalesce` fallback keeps rows created before the migration correct with **no backfill**.
*Alternative considered:* pure `SUM(jsonb_array_length(raw_messages))` with no new column — correct and
zero-migration, but lengths the JSON on every status poll; acceptable as a fallback but the column is
cheaper long-term. (Either satisfies the spec; implementer picks one — the column is preferred.)

### D3 — "detected" is a count of the run's surfaced evidence
Report `detected` per run as `COUNT(*)` of `detected_billing_events` for the run (equivalently pending
`subscription_candidates`), not the `events_detected` column. *Why:* the bridge no longer writes
`events_detected`, so the column is stale (0); the candidate/evidence rows are the real, already-persisted
tally and are inherently cumulative and retry-safe (upsert on natural key).

### D4 — "likely-billing" = cumulative Tier-1 triage look count
Persist the triage "look" count per page: add `scan_jobs.triage_look_count int` (nullable), set by the
managed page task from the `triage` result that `runTwoTierScan` already returns (`analyzeInboxPage`
currently destructures only `{ proposals }` and drops `{ triage }`). Report `candidate_messages` as the
cumulative `SUM(triage_look_count)` for the run. *Why:* the current value (raw fetched count == messages)
is meaningless as "likely billing"; the triage look-set is the funnel's actual billing-relevance signal.
*Alternative:* leave `candidate_messages` mirroring the fetched count but make it cumulative — cheaper
(no worker change) but keeps a misleading number. **Chosen behavior:** `SUM(triage_look_count)` with no
fetched-count fallback, so during a partial rollout (old pages with null counts) it reads a lower true
number, and reads 0 until any page records a count — honest rather than misleading. This is
non-decreasing as new pages record counts, satisfying the spec.

### D5 — Which pages count toward progress
Sum over **all page rows handed to analysis** for the run (any status), so "messages checked" climbs as
pages are fetched/enqueued rather than only in terminal jumps. `detected` naturally reflects only pages
that actually surfaced evidence. *Why:* matches the "scan is visibly alive" goal.

## Risks / Trade-offs

- **Heavier status query** (now aggregates page rows per run) → Mitigation: aggregate in SQL over a
  small int column (D2), ≤30 rows/run; avoid selecting `raw_messages` into JS.
- **`raw_messages` fallback cost for old rows** → Mitigation: only pre-migration rows hit
  `jsonb_array_length`; new rows use `message_count`.
- **D4 requires a worker + edge change in one release** → Mitigation: columns are additive/nullable;
  if the worker half lags, `candidate_messages` degrades to a cumulative fetched count (still
  non-decreasing), not an error.
- **Run-level cache columns drift from the aggregate** → Mitigation: stop treating them as
  app-visible; keep only as debug/denormalized values (or write them from the same aggregate at
  finalize time).

## Migration Plan

1. Additive, nullable migration: `alter table public.scan_jobs add column if not exists message_count int`,
   `add column if not exists triage_look_count int`. No backfill (coalesce fallbacks cover old rows).
2. Edge: set `message_count` when enqueuing the page's `scan_jobs` row; switch status derivation
   (`scanned`/`candidate_messages`/`detected`, and `runs[]` entries) to the per-page aggregates.
   `deno check` + redeploy `email-scan`.
3. Worker: thread `triage.lookCount` from `analyzeInboxPage` into `triage_look_count` on the page row;
   typecheck + redeploy the trigger.dev tasks.
4. Rollback: revert the edge status derivation to the run-column read; the nullable columns can remain
   (harmless). No data migration to undo.

## Open Questions

- Should the run-level cache columns be **kept in sync** by the finalizer (write the computed totals at
  completion) for history/notifications, or left unused and read purely from the ledger? Leaning: write
  them once at finalize so `recent_activity` / notifications keep working off `email_scan_runs`.
- Is `detected` better sourced from `detected_billing_events` (evidence) or pending
  `subscription_candidates` (review cards)? They match today (6 = 6); pick candidates if the app's
  "changes to review" is the intended meaning.
