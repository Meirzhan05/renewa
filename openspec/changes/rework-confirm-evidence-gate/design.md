## Context

The confirm-time lifecycle gate was written when a deterministic pipeline populated evidence rows and
"no matching evidence" reliably meant "this merchant has no billing history". Under the autonomous
agent that inference no longer holds, and the gate's failure mode is a silent one: it marks the card
ignored and returns HTTP 200.

`restore-detected-event-identity` restores what the gate reads. This change reconsiders what the gate
is *for*. Today:

```
user taps Track / Confirm
        │
        ▼
  reviewCandidate
        │
   lifecycle.state != "current"  ──yes──►  resolveCandidateForLifecycle
        │                                     review_status = 'ignored'
        no                                    no subscription
        ▼                                     HTTP 200  ← indistinguishable
   create subscription                                    from success
```

The gate protects something real: evidence that a subscription was cancelled should not be
resurrected by a stale card the user taps without reading. But it currently exercises that judgment
*after* the human has exercised theirs, invisibly, and on strictly less information than the human
had — the human sees the merged card and can type corrections; the gate sees only raw event rows.

Target shape:

```
user taps Track / Confirm
        │
        ▼
  reviewCandidate  (evidence = events + merged card + submitted edits)
        │
   contradiction found?  ──yes──►  return warned + reason, card stays pending
        │                              │
        no                             ▼
        │                        user reads it, decides
        ▼                              │
   create subscription   ◄──────── proceed (acknowledged)
                                       │
                                    decline → nothing recorded
```

Live evidence motivating each part: one card marked `ignored` at `2026-09-02 23:57:54Z` with no
subscription created; a pending `OpenAI` card backed by a bare `renewed` event that can never satisfy
`isPaidRecurringEvent`; and `0 of 4` subscriptions carrying a canonical merchant key, which makes the
bridge's tracked-subscription lookup — filtered `where canonical_merchant_key is not null` — empty in
practice.

## Goals / Non-Goals

**Goals:**

- A human confirmation always results in either an applied subscription or a warning the human
  resolves. Never a silent refusal.
- Every outcome is distinguishable by the client, and the client never reports an unapplied decision
  as saved.
- The gate judges on the same information the user had: evidence records, the merged card, and the
  edits just submitted.
- A subscription, however created, carries a merchant identity the agent can match, so confirming
  something does not lead to being offered it again.

**Non-Goals:**

- Removing the staleness check. The concern it encodes is legitimate; only its authority over a human
  decision is being removed.
- Re-identifying existing rows. Fix-forward remains the standing decision; the four unkeyed
  subscriptions and the wrongly-ignored card are not repaired by this change.
- Changing what the agent proposes, how proposals are scored, or how cards are merged.
- Redesigning the review sheet. The warning is added to the existing flow rather than replacing it.

## Decisions

### Warn-then-acknowledge in the existing endpoint, rather than a preflight call

The server returns a warned outcome that leaves the card pending; the client shows the reason and, if
the user proceeds, re-submits the same decision with an acknowledgement.

*Alternative rejected — carry a lifecycle advisory on each candidate in the scan-status payload, and
always apply on confirm:* it avoids a round trip and could warn before the tap, but the advisory is
computed at scan time and read at confirm time, so it can be arbitrarily stale — the exact class of
error the gate exists to catch. It also spends payload on every card to serve the rare one.

*Alternative rejected — a separate preflight endpoint:* a second network call on the happy path, a
new endpoint to authenticate and version, and a TOCTOU window between preflight and confirm. The
warned outcome carries the same information at the moment it is actually true.

The cost is a second round trip on the rare warned path, which is the path where the user is reading
a dialog anyway.

### Evidence for the warning is the union of records, card, and edits

`isPaidRecurringEvent` currently demands amount, currency, and cycle on a single event row. Under
per-merchant rollup, those fields legitimately live on the merged card while each individual event
carries a subset. The check becomes: does the *decision as submitted* describe a current paid
subscription, and does any stored evidence *contradict* it?

This reframes the test from **absence** to **contradiction**, which is the only version that can be
stated honestly to a user. "We could not find recurrence evidence" is not something to say to someone
who just typed the amount in.

*Alternative rejected — keep the events-only rule and simply let more cards through:* leaves the
warning firing on cards the user completed, which trains them to dismiss warnings.

### `resolveCandidateForLifecycle` survives, but not on a human path

It is still correct for automatic reconciliation, where no human decision is being overridden. The
change is that `reviewCandidate` no longer calls it. Keeping the function avoids conflating "the
system tidied up a stale card" with "the system refused a person".

### Identity flows from the card to the subscription, and is assigned on every creation path

Confirm takes the candidate's `canonical_merchant_key` instead of `canonicalMerchantKey(merchantName)`.

`source_key` stays name-derived and is now computed separately. It is the conflict target of the
confirm upsert, so moving it to the card's identity would strand every subscription an earlier
confirmation created under the old key — a re-confirm would insert a duplicate rather than update.
Dedupe-on-write and identity-for-matching are separate jobs and only the latter has to agree with the
card. (The design originally assumed the two moved together and that a migration would reconcile
them; separating them removes the migration and its risk entirely.)

**Where a manual subscription's identity comes from.** Manual creation writes straight from the
client to PostgREST, so nothing on that path can set the column without a second copy of the
derivation. There are exactly two consumers of the column, `candidate-bridge.ts` (write-boundary
dedupe) and `reconcile-db.ts` (what the agent is told the user tracks), and both are worker
TypeScript that already imports `canonicalMerchantKey`. So identity is derived at the point of use:
each reader selects `name` alongside the key and falls back to `canonicalMerchantKey(name)` when the
column is null.

One implementation, in the module that owns it, no migration, and every manual subscription already
in the database starts being recognized immediately rather than only newly created ones.

*Alternative rejected — a Postgres trigger populating the column on insert:* it would cover every
path, but puts a second copy of the slug rules in SQL, which is exactly what
`dedupe-inbox-proposals-by-merchant` refused ("re-deriving them would put a second copy … in SQL,
where it would drift"). Exact NFKD and `\p{Letter}` parity with the TypeScript is also difficult to
guarantee.

*Alternative rejected — compute it in Swift on manual insert:* a third copy of the rule, covering
only the iOS path, and it does nothing for the manual rows that already exist.

*Alternative rejected — match tracked subscriptions by name similarity when the key is null:* fuzzy
matching across a boundary that already has a deterministic identity mechanism, and the failure mode
is fusing two real subscriptions, which the user cannot see to correct.

### The client's review call returns an outcome, not a Bool

`reviewEmailCandidate` currently returns `Bool` and derives it from "no error was thrown", which is
why a refusal reads as a success. It returns a typed outcome instead, and
`EmailScanView.resolve(_:_:)` rolls the optimistic collapse back on anything that is not applied.
`EmailCandidateDecisionResponse` already decodes the fields needed (`Models.swift:572`); they are
currently discarded at `AppStore.swift:498`.

## Risks / Trade-offs

- **A warning dialog on a path that used to be one tap** → Only on the warned path, which is rare
  once identity is restored. Measure how often it fires before considering softening it.
- **Users click through warnings** → Accepted. An explained, overridable warning is strictly better
  than a silent veto, and the user is the one who can see their own inbox.
- **`source_key` and `canonical_merchant_key` now derive differently on the same row** → Deliberate,
  and commented at the write site. The risk is a later reader assuming they agree; they answer
  different questions and only identity is meant to match the card.
- **Assigning identity to manual subscriptions makes the agent match rows it never matched** →
  Intended, but it changes proposals from "add" to "update" for merchants the user tracks. Verify the
  update path is safe before enabling, since an update writes to a subscription the user created.
- **This change depends on `restore-detected-event-identity`** → Without keyed evidence every
  lifecycle reconstruction is empty, so a contradiction test would find nothing to contradict and the
  behaviour would silently reduce to "always apply". Ship them in order.
- **Two clients can disagree during rollout** → An older iOS build does not know the warned outcome.
  It must not read an unknown outcome as success; the transparency spec requires exactly that, and it
  should be verified against the shipped build before the server change is deployed.

## Migration Plan

1. Land and deploy `restore-detected-event-identity` first; confirm evidence rows are keyed.
2. Server: warned outcome and acknowledgement in `reviewCandidate`; contradiction-based evidence
   test; identity inherited by the created subscription.
3. Worker: derive identity at the two readers so manual subscriptions are recognized. No migration.
4. Client: typed outcome, response consumed, warning surfaced, optimistic rollback on non-applied.
5. Verify with the real inbox: a normal confirm applies in one tap; a cancelled-merchant card warns
   and applies on acknowledgement; a confirmed subscription is not re-proposed by the next scan; a
   manually added subscription is not proposed at all.
6. Rollback: the server change is independently revertible. The migration is additive — assigning
   keys where there were none — and does not need reversing.

## Open Questions

- Should a warning the user overrides be remembered, so the same card does not warn again after a
  later scan re-raises it? The review outcome record may already be the place for that.
- Does the `unknown-merchant` sentinel deserve to be excluded from tracked-subscription matching?
  Two unrelated subscriptions both falling back to the sentinel would match each other. Raised as an
  open question in `restore-detected-event-identity` and best settled here.
- Should the review sheet show the lifecycle evidence — the events behind the card — before the user
  confirms, rather than only warning after? That would move the judgment earlier, where the user has
  the most context, but it widens the change into the sheet's design.
