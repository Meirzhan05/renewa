## Why

Confirming a discovery from the inbox does nothing. The user taps Track (or Confirm in the review
sheet), the card collapses, the app reports success — and no subscription appears. Observed live at
`2026-09-02 23:57:54Z`:

```
merchant_name          | review_status | applied_subscription_id | system_resolution_reason
Anthropic (Claude Pro) | ignored       | NULL                    | "Current renewal evidence is
                                                                    unavailable for this merchant."
```

The confirm handler gates every confirmation on a merchant lifecycle it rebuilds from
`detected_billing_events`, selected by `canonical_merchant_key` (`email-scan/index.ts:962`). That
column is **NULL on every row in the table**:

```sql
select count(*) total, count(canonical_merchant_key) with_key from detected_billing_events;
--  total | with_key
--     13 |        0
```

`f5e2dfa` ("Cut inbox scanning over to the autonomous LLM agent", 2026-08-28) deleted the
deterministic pipeline that used to populate that column and replaced it with
`candidate-bridge.ts`, whose INSERT omits it. The bridge resolves a merchant identity and writes it
onto the *candidate*; it never writes it onto the *event*. The gate reads the event side, so it
matches zero rows, concludes `state: "uncertain"`, and silently resolves the card to `ignored`
without applying it.

The bridge is now the only writer of that table, so this affects every discovery the agent has
produced since Aug 28 — the review queue has been decorative for five days. The same lookup backs
the learning summary that feeds the Inbox screen's "Tracked automatically" section
(`index.ts:1396`), which has been equally blind.

## What Changes

- `candidate-bridge.ts` writes the resolved merchant identity onto the `detected_billing_events`
  row, using the **same** `identity` value it already computes for the candidate — one resolution
  per proposal, written to both rows, so the two can never disagree.
- The event upsert's `DO UPDATE` branch also sets the key, so a re-scan of an email whose event row
  predates this change repairs that row in place. This is convergence through the normal scan path,
  not a data migration: rows are only rewritten when the agent re-derives the same event.
- No schema migration. `detected_billing_events.canonical_merchant_key` already exists, is nullable,
  and its check constraint (`^[a-z0-9][a-z0-9-]{0,79}$`) is already satisfied by every value
  `canonicalMerchantKey` can produce.
- No backfill of existing rows and no reopening of the card wrongly marked `ignored`. Fix-forward
  only, by explicit decision.

### What this deliberately does not fix

Named here so the remaining gap is visible rather than discovered later. All three are the subject of
the follow-up change `rework-confirm-evidence-gate`:

- **A refusal still looks like a success.** The gate returns HTTP 200 with
  `review_status: "ignored"`; `AppStore.reviewEmailCandidate` discards the response body
  (`AppStore.swift:498`) and returns `true`. Any confirmation the gate still declines will continue
  to be reported to the user as saved.
- **Cards backed by a thin event stay unconfirmable.** The pending `OpenAI (ChatGPT Plus)` card is
  backed by a single bare `renewed` event with no amount, currency, or cycle. It can never satisfy
  `isPaidRecurringEvent`, so its lifecycle stays `uncertain` even once keys are written — including
  when the user types the missing amount into the review sheet themselves.
- **Confirm keys the subscription it creates by display name.** `index.ts:1653` uses
  `canonicalMerchantKey(merchantName)` (`anthropic-claude-pro`) while the bridge matches
  subscriptions by sender-derived identity (`anthropic`), so a successfully confirmed subscription
  is not recognized by the next scan and is offered again as a fresh "add".

## Capabilities

### New Capabilities
- `evidence-record-identity`: every evidence record the agent writes carries the same canonical
  merchant identity as the review card it backs, so any consumer that reconstructs merchant history
  from evidence — the confirm-time lifecycle gate, the learning summary, evidence bundles — can find
  it.

### Modified Capabilities
None. No existing requirement changes; this restores an invariant that was silently dropped.

## Impact

- `worker/src/agent/candidate-bridge.ts` — the `detected_billing_events` INSERT gains
  `canonical_merchant_key` in its column list, values, and `DO UPDATE` set. Purely additive:
  `identity` is already resolved at line 80, above the event insert, and already feeds the candidate
  write, so one value feeds both without reordering.
- `worker/test/candidate-bridge.test.ts` — assert the event row carries the identity, that it equals
  the candidate's key, and that a re-upsert of an unkeyed row repairs it.
- `supabase/functions/email-scan/index.ts` — unchanged. `merchantLifecycle` (962),
  `learningSummary` (1396) and `reviewCandidate` (1591) are readers that start finding rows.
- No migration, no iOS change, no worker deployment config change.
- Unblocks: cards whose evidence includes a complete paid-recurring event (the `Anthropic` case,
  verified by hand to resolve to `state: "current"` once keyed). Does not unblock the `OpenAI` case.
