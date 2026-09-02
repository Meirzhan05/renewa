## Context

"Emails checked" in the app is the `scanned` field, which the status endpoint (`email-scan/index.ts`) fills from the `email_scan_batch_progress(p_user_id, p_batch_id)` RPC. That function computes `messages_scanned` as:

```sql
sum(coalesce(s.message_count, jsonb_array_length(s.raw_messages)))  -- over ALL scan_jobs of the run
```

`scan_jobs.message_count` is written when the page row is **created** by `scan-inbox-run` (`index.ts:874`, `providerBatch.metadata.length`). `scan-inbox-run` paginates the mailbox and enqueues one page row per window far faster than `analyze-inbox-page` reasons over them (measured: 30 rows enqueued in ~4 min; agents still finishing 20+ min later). So the all-rows sum reports *emails enqueued*, and the counter jumps to the full inbox size almost immediately, then sits frozen while the real work continues (live run: 3000 shown vs 1800 actually processed).

This all-rows sum was introduced by `202608300003` to fix an earlier bug where `messages_scanned` was overwritten with the latest page's count and **froze at ~100**. Summing across pages fixed the freeze but overshot by ignoring page status. `finalize_email_scan_run_if_drained` (latest definition in `202608300007`) denormalizes the same all-rows sum onto `email_scan_runs` at terminal state.

## Goals / Non-Goals

**Goals:**
- The live "emails checked" number reflects emails the analysis agents have processed, climbing as pages complete.
- The persisted run total agrees with the live number and is honest for runs with failed pages.
- No app/API change; the existing `scanned` field just carries the right value.

**Non-Goals:**
- No change to `likely_billing`/`detected` derivation.
- No "X of Y" progress bar (would require Swift work); noted as a follow-up only.
- No change to duplicate-row handling (the separate `fix-managed-scan-page-counts` / progress-dedup concern).
- No sub-page granularity (per-message live counting); page-level (~100) steps are sufficient.

## Decisions

### Decision 1: Sum `message_count` over `status = 'completed'` pages only

Add `filter (where s.status = 'completed')` to the `messages_scanned` sum in both `email_scan_batch_progress` and the `v_scanned` computation inside `finalize_email_scan_run_if_drained`. A page's emails are "checked" once its agent finishes (status `completed`); `pending` hasn't started, `running` is mid-check, `failed` was never checked.

**Why completed-only (not completed+running):** honesty — a running page's emails aren't checked yet, and on the observed run the two were equal anyway. The counter stepping by 100 as each page finishes is smooth enough at ~1 page/min.

**Alternatives considered:**
- *Keep all-rows sum.* Rejected: that is the bug — it measures the fetcher, not the agents.
- *Write `message_count` at page completion instead of creation.* Would also work, but the value is only known at creation (it is the window size) and the fallback to `jsonb_array_length(raw_messages)` assumes it is set early; moving the write is more invasive than filtering the read. Rejected in favor of the read-side filter.
- *Add a separate processed-count column the agent increments.* Redundant with page status; more moving parts. Rejected.

### Decision 2: Leave `likely_billing`/`candidate_messages` as the all-rows sum of `triage_look_count`

`triage_look_count` is written by the agent *during* analysis (only for pages it touches); pending pages contribute 0. So the all-rows sum already tracks agent progress for that metric — no filter needed, and adding one risks divergence from how it is recorded. Keep it unchanged in both functions.

### Decision 3: One migration redefining both functions on top of the latest definitions

Create a new migration that `create or replace`s `email_scan_batch_progress` (base: `202608300003`) and `finalize_email_scan_run_if_drained` (base: the cancellation-aware `202608300007`, preserving cancel-wins precedence and all other behavior). Only the `messages_scanned`/`v_scanned` sum gains the completed-only filter.

## Risks / Trade-offs

- **[Completion total drops for runs with failed pages]** → `messages_scanned` will read < full inbox when pages failed. This is intended and pairs with the failed-state UI; call it out so it is not mistaken for a regression. Mitigation: none needed — it is the honest number.
- **[Rows predating `202608300003` have null `message_count`]** → the `coalesce(..., jsonb_array_length(raw_messages))` fallback is retained inside the filtered sum, so completed legacy rows still count.
- **[Divergence between live and persisted values]** → avoided by applying the identical filter in both functions; a test asserts they agree for the same fixture.
- **[Duplicate `scan_jobs` rows]** → out of scope here; if two `completed` rows exist for one logical page they would still double-count. Tracked separately (progress-dedup). Note the current production run shows no duplicates.

## Migration Plan

1. Add `supabase/migrations/<ts>_count_checked_by_completed_pages.sql` redefining both functions with the completed-only `messages_scanned` sum; everything else byte-for-byte from the latest definitions.
2. `supabase db push` to apply. Read-side only — no data backfill; in-flight and future scans immediately report the corrected number.
3. **Rollback:** re-apply the `202608300007` + `202608300003` definitions (drop the filter). No data to unwind.

## Open Questions

- Do we also want the "X of Y checked" progress bar now that both numbers are cheaply available (numerator = completed sum, denominator = all-rows sum)? Deferred to a follow-up UI change unless the single corrected number is deemed insufficient.
- Should a cancelled run count completed pages up to the cancel point (current behavior with the filter) or report 0? Current behavior (count what was actually checked) seems right; confirm during review.
