## 1. Write the identity onto the evidence record

- [x] 1.1 In `worker/src/agent/candidate-bridge.ts`, add `canonical_merchant_key` to the
      `detected_billing_events` INSERT: the column list, a new bound parameter carrying the
      `identity` already resolved at line 80, and the `do update set` clause
      (`canonical_merchant_key = excluded.canonical_merchant_key`) so a re-scan repairs an unkeyed
      row in place. Do not re-derive identity at the event — reuse the one variable that already
      feeds the suppression check and the candidate write.
- [x] 1.2 Comment why the column is written here: the confirm-time lifecycle gate, the learning
      summary, and evidence bundles all select evidence by this key, so an evidence row without it
      is invisible to every merchant-scoped read. Note that `dedupe-inbox-proposals-by-merchant`
      task 2.4 deliberately left this insert untouched, which is where the invariant was lost.

## 2. Lock the invariant in tests

- [x] 2.1 In `worker/test/candidate-bridge.test.ts`, assert that bridging a proposal writes a
      `detected_billing_events` row whose `canonical_merchant_key` **equals the key written to the
      `subscription_candidates` row for the same proposal** — assert the equality, not a literal, so
      a future change that alters identity derivation on one path only fails here.
- [x] 2.2 Add a case where identity falls back (unparseable sender, or an aggregator sender) and
      assert the evidence row carries the fallback key rather than a null or a processor-derived key.
- [x] 2.3 Add a case where two proposals from the same registrable sender domain carry different
      display names, and assert both evidence rows and the single merged card share one key.
- [x] 2.4 Add a case that re-upserts an existing evidence record whose `canonical_merchant_key` is
      null and assert the conflict branch sets it, without creating a second row.

## 3. Verify against real data

- [x] 3.1 Run `npm run typecheck` and the worker test suite in `worker/`; all existing tests must
      still pass.
- [x] 3.2 Deploy the worker only. Confirm no migration, no edge function deploy, and no iOS build
      are part of this change.
- [x] 3.3 Run a scan against the real inbox, then check
      `select count(*), count(canonical_merchant_key) from detected_billing_events` — newly written
      rows must be keyed. Spot-check that a new row's key equals its card's key.
- [x] 3.4 Confirm the pending `Anthropic (Claude Pro)` card from the app. Verify a `subscriptions`
      row is created, the card reaches `review_status = 'confirmed'` with a non-null
      `applied_subscription_id`, and the subscription appears on the Home screen.
- [x] 3.5 Confirm the failure that remains: the pending `OpenAI (ChatGPT Plus)` card is backed by a
      bare `renewed` event with no amount, currency, or cycle. Verify it still resolves to `ignored`
      on confirm, and record that as the motivating case for `rework-confirm-evidence-gate` rather
      than treating this change as incomplete.
- [x] 3.6 Observe whether the next scan re-offers the now-confirmed `Anthropic` subscription as a
      fresh `add` card. Expected yes — confirm keys the created subscription `anthropic-claude-pro`
      while the bridge matches `anthropic`. Record the result in the follow-up change's evidence.

## 4. Hand off what stays broken

- [x] 4.1 Tell the user plainly which cards this fixes and which it does not, so a partial fix is not
      read as a complete one: cards whose evidence includes a complete paid-recurring event now
      confirm; thin-evidence cards still vanish silently, and any refusal the gate still issues is
      still reported to them as a successful save.
