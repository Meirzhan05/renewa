## 1. Surface uncertain discoveries (D1)

- [x] 1.1 In `reconcilePendingCandidates` (`email-scan/index.ts`), replace the
      `suppressed || lifecycle.state !== "current"` rule with the pure `discoveryReconcileAction` helper,
      so an `uncertain` merchant no longer hides a first-time discovery (only suppressed/ended do).
- [x] 1.2 Cancellation, ended, and suppressed auto-resolve reasons preserved via the helper's mapped
      reasons.

## 2. Stop reconciling in-progress runs (D2)

- [x] 2.1 Select `scan_run_id` on the pending candidates and skip any candidate whose run is still
      `queued`/`running` (fetched once per reconcile) — no reconciliation during an active scan.
- [x] 2.2 Settled candidates (terminal run, or no active run) are still reconciled.

## 3. Tests

- [x] 3.1 Pure `discoveryReconcileAction` unit tests: `uncertain` → keep (surfaced); `ended` → resolve;
      `suppressed` → resolve; `current` → keep.
- [x] 3.2 Test that an active-run candidate is never reconciled (all lifecycle states → keep).
- [x] 3.3 Idempotency test: repeated reconcile over the same state does not flip a candidate; plus the
      cancellation supersede/keep cases.

## 4. Optional surfacing polish (D3) and backfill (D4)

- [ ] 4.1 (Optional) Tag surfaced-but-uncertain candidates so the review card can label them.
- [ ] 4.2 (Optional) One-off, reversible re-open of recent system-resolved `uncertain` discovery ignores
      (by `system_resolution_reason` within a bounded window) so existing users see what was hidden.

## 5. Verification and release

- [x] 5.1 Edge `deno check` clean + tests green (26 pass).
- [ ] 5.2 On a real scan, confirm a discovery with missing amount or an old renewal now appears in the
      review queue (`pending_count > 0`), while a cancelled/suppressed merchant stays hidden.
- [ ] 5.3 Deploy the updated `email-scan` function; verify against this account that ChatGPT/Claude
      surface for review.
