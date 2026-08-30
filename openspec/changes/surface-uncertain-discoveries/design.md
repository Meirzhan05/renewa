## Context

`reconcilePendingCandidates(admin, userID)` is called at the top of `scanStatus` — so on **every**
status poll. For each pending candidate it computes the merchant lifecycle
(`reconcileMerchantLifecycle` over that merchant's `detected_billing_events`) and, for a non-cancellation
("add") candidate, resolves it to `ignored` when `suppressed || lifecycle.state !== "current"`
(`index.ts:1424`).

`current` requires a paid-recurring event — `amount > 0` + `^[A-Z]{3}$` currency + a `billing_cycle`
(`email-discovery.ts:isPaidRecurringEvent`) — whose renewal (explicit `renewal_date` or projected from
`event_date` + cycle) is `>= today`. Anything else is `uncertain` (or `ended` on an explicit
cancellation). So the current rule hides every discovery that isn't provably, currently renewing —
including brand-new ones the person has never seen. Measured: 4/4 real discoveries hidden.

The app already treats these as "non-actionable" (`nonActionableCount = ended + uncertain + …`), i.e.
the hiding is deliberate — but it is wrong for **first-time** discovery, and it is compounded by running
mid-scan (before a candidate's own evidence is fully written).

## Goals / Non-Goals

**Goals:**
- First-time discoveries reach the review queue unless the merchant is suppressed or explicitly ended.
- Lifecycle reconciliation no longer races an in-progress scan.
- Keep the legitimate cross-run reconciliation (e.g. a cancellation superseded by a later renewal).

**Non-Goals:**
- Changing the lifecycle math (`current`/`uncertain`/`ended` definitions).
- Fixing extraction so amount/cycle are captured (separate; ChatGPT came back empty).
- Any client contract change.

## Decisions

### D1 — Only auto-resolve discoveries that are suppressed or explicitly ended
Change the discovery branch from `suppressed || lifecycle.state !== "current"` to
`suppressed || lifecycle.state === "ended"`. `uncertain` no longer hides a discovery; it stays pending
for review. *Why:* the review queue exists precisely for "we can't confirm this is current" — that is a
person's call, not a silent auto-ignore. `ended` (an explicit cancellation supersedes the add) and
`suppressed` (the person opted out) remain the only auto-hide reasons.
*Alternative — surface everything including `ended`:* rejected; an add whose merchant was explicitly
cancelled later is genuinely stale, and suppression must be honored.

### D2 — Do not reconcile candidates from a still-active run
Guard `reconcilePendingCandidates` so it skips candidates whose `scan_run_id` belongs to a run that is
not yet terminal (still `queued`/`running`). Only settled runs' candidates are reconciled. *Why:*
running reconcile every poll during a scan judged Claude's August receipt before its future-renewal
event landed and hid it. Implementation: restrict the pending-candidate query to candidates whose run is
terminal (join/filter on `email_scan_runs.status in ('completed','failed','cancelled','partial')`, or
exclude runs with active edge/worker jobs). Cross-run reconciliation of already-settled candidates is
unaffected.

### D3 — Tag surfaced-but-uncertain candidates (optional, non-breaking)
When a discovery is surfaced while `uncertain`, record a lightweight signal (e.g. append to the existing
`validation_issues`, or a `resolution_reason`/note) so the review card can label it "couldn't confirm
this is currently active." *Why:* preserves the original intent (don't over-trust ambiguous evidence)
without hiding it. Optional — the core value is D1+D2.

### D4 — Re-open recently auto-hidden discoveries (optional, one-off)
A bounded data fix that flips recent `system_resolved` `uncertain` discovery ignores back to `pending`
(e.g. `system_resolution_reason` = the "current renewal evidence is unavailable" message, within a
recent window), so existing users immediately see what was hidden. *Why:* without it, only *new* scans
benefit; the current test account's ChatGPT/Claude stay hidden. Scoped and reversible.

## Risks / Trade-offs

- **More review noise (old one-off receipts surface)** → Mitigation: only `uncertain` is surfaced, and
  only for candidates the agent already judged worth proposing; `ended`/suppressed stay hidden; D3 labels
  the uncertain ones so the person can dismiss quickly.
- **D2 filter accidentally excludes settled candidates** → Mitigation: treat only clearly-active runs as
  "hold"; default to reconciling when run state is unknown/terminal; cover with tests.
- **D4 re-opens something a user already dismissed** → Mitigation: only re-open *system*-resolved
  (`system_resolved_at` set) ignores with the specific lifecycle reason, never user decisions; bounded
  time window.

## Migration Plan

1. Edge: apply D1 + D2 in `reconcilePendingCandidates`; `deno check` + tests; redeploy `email-scan`.
2. (Optional) D3 tag; D4 one-off re-open (idempotent, reversible).
3. Rollback: revert the reconcile predicate; no schema change to undo.

## Open Questions

- D3: reuse `validation_issues` vs. a dedicated "unconfirmed_current" flag (UI dependency)?
- D2: filter by run terminal-status vs. by "no active jobs for the batch" — pick the one that composes
  with the paginated-completion status the finalizer already sets.
- Should `ended`-superseded adds be surfaced-but-labeled instead of hidden? (Kept hidden for now.)
