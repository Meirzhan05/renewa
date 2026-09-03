## Context

`detected_billing_events` is the evidence record: one row per email the agent drew a conclusion from.
`subscription_candidates` is the review card the user acts on. Both are written by
`candidate-bridge.ts`, which since `f5e2dfa` is the only writer of either table.

`canonical_merchant_key` is the join between them and every merchant-scoped read in the edge
function. The bridge writes it on the card and omits it on the event. Three consumers select evidence
by that key and therefore see nothing the agent has written:

```
                    candidate-bridge.ts
                            │
             ┌──────────────┴──────────────┐
             ▼                             ▼
  detected_billing_events        subscription_candidates
  canonical_merchant_key         canonical_merchant_key
        = NULL  ✗                      = 'anthropic'  ✓
             │                             │
             │  ┌──────────────────────────┘
             ▼  ▼
    merchantLifecycle(userID, candidate.canonical_merchant_key)
      SELECT … WHERE canonical_merchant_key = 'anthropic'  →  0 rows
             │
             ▼
    reconcileMerchantLifecycle([])  →  state: "uncertain"
             │
             ▼
    reviewCandidate: stale → resolveCandidateForLifecycle → 'ignored', HTTP 200
```

The gate at `index.ts:1597-1611` was written when the deterministic pipeline populated the column, so
"no evidence found" reliably meant "this merchant has no billing history". Under the agent it means
"the bridge did not write a column", and the gate cannot tell those apart.

Verified live: 13 evidence rows, 0 keyed; one card marked `ignored` by the gate at `23:57:54Z` with
`applied_subscription_id` null; newest `subscriptions` row still dated 2026-07-29.

## Goals / Non-Goals

**Goals:**

- Every evidence record the bridge writes carries the identity of the card it backs.
- The identity on the event and the identity on the card are the same value, resolved once, so they
  cannot drift as identity rules evolve.
- Evidence rows written before this change converge on the correct key through the normal scan path,
  without a data migration.
- Confirming a card whose evidence contains a complete paid-recurring event applies it and creates a
  subscription.

**Non-Goals:**

- Changing the lifecycle gate's semantics, its inputs, or what it does when it refuses. The gate
  stays a silent veto in this change; `rework-confirm-evidence-gate` makes it advisory.
- Making the iOS client distinguish a refusal from a success. Also `rework-confirm-evidence-gate`.
- Making cards backed only by a thin event (no amount/currency/cycle) confirmable. The `OpenAI` card
  stays stuck after this change.
- Reconciling the display-name-derived key that confirm assigns to a created subscription with the
  sender-derived identity the bridge matches on.
- Backfilling the 13 existing rows, or reopening the card the gate wrongly ignored.
- Any schema change. The column, its nullability, and its check constraint already exist.

## Decisions

### Write the identity the bridge already resolved, rather than deriving it at the event

`resolveIdentity(p, input.messageSenders)` is already called at `candidate-bridge.ts:80`, above the
event insert, and its result already feeds the candidate write and the suppression check. The event
insert takes that same variable.

*Alternative rejected — derive identity inside the event insert from `merchant_name`:* SQL-side
`canonicalMerchantKey(merchant_name)` would yield `anthropic-claude-pro` where the card carries
`anthropic`, so the join would still miss. It also puts a second copy of the aggregator and
public-suffix rules somewhere they can drift — the failure mode `dedupe-inbox-proposals-by-merchant`
explicitly designed against.

*Alternative rejected — a database trigger populating the column:* it would need the sender, which
the row does not carry, so it could only re-derive from the display name and lands in the same trap.

### Repair through the upsert's conflict branch, not a migration

The event upsert conflicts on `(user_id, provider, provider_message_id, event_type)` and currently
updates `merchant_name`, `amount`, `renewal_date`, and `confidence`. Adding
`canonical_merchant_key = excluded.canonical_merchant_key` to that set means any re-scan that reaches
the same email repairs an unkeyed row in place.

This is convergence, not migration: rows change only when the agent independently re-derives the same
event, under the same identity rules that would have produced the value originally. It respects the
fix-forward decision while giving the existing rows a path back without a hand-written UPDATE that
would need its own copy of the identity rules.

*Alternative rejected — `coalesce(detected_billing_events.canonical_merchant_key, excluded.…)`:*
preserving an existing key would freeze whatever a row already has. Since every existing row is null
and identity resolution is deterministic, plain `excluded` is both simpler and self-correcting if
identity rules are later refined.

*Alternative rejected — a one-shot backfill migration:* explicitly declined. It could only key rows
from the display name (the sender is not stored on the row), which reintroduces the divergence this
change exists to remove.

### Keep the write inside the existing single statement

No new query, no second round trip, no change to the bridge's control flow or to the 23505 handling
in `insertOrMergeCandidate`. The blast radius is one INSERT's column list, one values list, and one
`DO UPDATE` clause.

### Assert the invariant in tests, not just the value

The regression was not "a wrong value" but "two rows that were supposed to agree stopped agreeing".
The test that protects it asserts *equality between the event key and the candidate key* for the same
proposal, so a future change that alters identity derivation on one path and not the other fails
loudly. A test that merely asserted `canonical_merchant_key === 'anthropic'` would not have caught
the original regression, because the original regression was on the column that no test looked at.

## Risks / Trade-offs

- **The gate stays a silent veto until the follow-up change lands** → Accepted deliberately. This
  change is scoped to ship immediately; the proposal names the gap in "What this deliberately does
  not fix" so it is visible rather than discovered by a user losing another save. Any card the gate
  still refuses will still be reported as saved.
- **Cards backed by a thin event remain stuck, and the user cannot tell why** → The pending `OpenAI`
  card will still vanish on confirm. Verify after deploying and warn the user, rather than letting
  them read a partial fix as a complete one.
- **A repaired row's identity may differ from what a much older scan would have produced** →
  Harmless: identity resolution is deterministic on `(sender, display name)`, and every existing row
  is null, so there is no prior value to contradict.
- **A row whose email falls outside every future scan window keeps a null key forever** → Accepted
  under fix-forward. Those rows contribute nothing to lifecycle reconstruction, exactly as today.
- **The suppression check runs on `identity` before the event insert** → Unchanged behaviour; a
  suppressed merchant writes neither row, as now.

## Migration Plan

1. Change `candidate-bridge.ts`; extend `candidate-bridge.test.ts`.
2. `npm run typecheck` and the worker test suite in `worker/`.
3. Deploy the worker. No edge function deploy, no migration, no iOS build.
4. Run a scan against the real inbox. Confirm `count(canonical_merchant_key) > 0` on
   `detected_billing_events`, and that keys on new rows match their cards'.
5. Confirm the pending `Anthropic (Claude Pro)` card from the app; verify a `subscriptions` row is
   created and that the card moves to `confirmed` with a non-null `applied_subscription_id`.
6. Rollback: revert the worker deploy. Rows keyed in the meantime stay keyed and stay correct —
   nothing else reads the column in a way that a partial rollout breaks.

## Open Questions

- Should the bridge refuse to write an evidence record at all when identity resolution returns the
  `unknown-merchant` sentinel? Today that key is written and behaves like any other, which can fuse
  unrelated merchants under one identity. Out of scope here; worth deciding in
  `rework-confirm-evidence-gate`, where identity semantics are already being examined.
- After step 5, does the confirmed `Anthropic` subscription get re-offered as a new card by the next
  scan? Expected yes, because confirm keys the subscription `anthropic-claude-pro` while the bridge
  matches `anthropic`. Confirm this empirically — it is the motivating evidence for the third item in
  the follow-up change.
