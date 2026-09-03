## Why

A human looked at a review card, read the evidence, and said yes. The server overruled them, marked
the card `ignored`, created nothing, and returned HTTP 200 — so the app told them it was saved. That
is the worst available outcome: a silent refusal dressed as a success.

`restore-detected-event-identity` fixes the immediate cause of the refusals (evidence rows written
without a merchant key, so the gate matched nothing). It deliberately leaves the shape of the
mechanism alone. Three problems survive it:

1. **The gate is a silent veto.** `reviewCandidate` reconstructs a merchant lifecycle from evidence
   rows and, if the state is not `current`, calls `resolveCandidateForLifecycle` — marking the card
   ignored and returning 200 (`index.ts:1597-1611`, `1914`). The user is never told, never asked,
   and cannot override.
2. **The gate cannot see what the user can.** It judges only raw evidence rows. The pending
   `OpenAI (ChatGPT Plus)` card is backed by one bare `renewed` event with no amount, currency, or
   cycle — never `isPaidRecurringEvent`, so its lifecycle is permanently `uncertain`. The card
   itself may carry those fields merged from a higher-confidence sibling proposal, and the review
   sheet invites the user to type a missing amount in. The user can supply exactly the evidence the
   gate says is absent and still be refused for its absence.
3. **A confirmed subscription is not recognized afterward.** Confirm keys the subscription it creates
   with `canonicalMerchantKey(merchantName)` — `anthropic-claude-pro` (`index.ts:1653`) — while the
   bridge matches tracked subscriptions by sender-derived identity — `anthropic`. The next scan does
   not recognize what the last confirmation created and offers it again as a fresh "add". This is
   precisely the duplication `dedupe-inbox-proposals-by-merchant` was written to eliminate,
   reappearing on the far side of the review.

   Observed on 2026-09-03, the first confirmation to succeed after
   `restore-detected-event-identity` shipped. The card carried identity `anthropic`; the
   subscription it created carries `canonical_merchant_key = 'anthropic-claude-pro'` and
   `source_key = 'email:anthropic-claude-pro'`. The bridge's lookup for `anthropic` will not find
   it, so the merchant is queued to be proposed again. The user's Home screen now also lists
   `Anthropic` (created 2026-07-29, `google:anthropic`, renewal 2026-07-23) alongside
   `Anthropic (Claude Pro)` (renewal 2026-09-22) — one subscription shown twice, because the
   confirm path had no way to recognize the older row as the same merchant.

The third problem is worse than a key mismatch. The bridge's lookup filters
`where canonical_merchant_key is not null`, and **0 of the 4 subscriptions in the live database carry
one** — two were added manually, and manual creation assigns no identity at all. The tracked-
subscription match is not merely wrong, it is empty. Every card the agent raises is an "add", even
for a subscription already on the user's Home screen. Under the fix-forward decision the user will
re-add Anthropic by hand, and the agent will propose it again after every scan, forever.

## What Changes

- **The lifecycle gate becomes advisory. A human confirmation always applies.** When lifecycle
  evidence suggests staleness, the server returns the card unapplied with a machine-readable reason
  and human-readable text instead of resolving it. The client shows that warning and lets the user
  proceed; proceeding re-submits with an explicit acknowledgement, and the server applies it. The
  server never silently overrules a human. **BREAKING**: the review endpoint gains a third outcome
  besides applied and ignored.
- **Every review outcome is distinguishable and reported truthfully.** `AppStore.reviewEmailCandidate`
  stops discarding the response body. A confirm that did not produce an applied subscription is not
  reported as success: the optimistic card rollback is undone and the user is told what happened.
  `EmailCandidateDecisionResponse` already decodes `reviewStatus` and `appliedSubscriptionID`
  (`Models.swift:572`) — the data is there and thrown away.
- **A subscription created by confirming a card inherits the card's merchant identity**, not a slug
  of its display name, so the next scan recognizes it and proposes an update rather than a duplicate
  add.
- **Manually created subscriptions get an identity too**, so the agent can recognize a subscription
  the user added by hand instead of proposing it every scan.
- The gate's *inputs* widen to what the user can see: the merged card's fields and the user's
  submitted edits count as evidence when deciding whether to warn, so a warning means "this looks
  stale to us", never "you did not give us a field you just typed".

## Capabilities

### New Capabilities
- `advisory-lifecycle-warning`: staleness detected at confirmation time is surfaced to the user as a
  warning they resolve, never as a silent server-side veto; the evidence considered includes the
  merged card and the user's edits, not raw event rows alone.
- `review-decision-transparency`: every outcome of a review decision is distinguishable by the
  client and reported to the user truthfully; a decision that did not apply is never presented as
  saved.
- `tracked-subscription-identity`: every subscription carries a canonical merchant identity —
  whether created by confirming a discovery or added by hand — so the agent recognizes what the user
  already tracks and stops re-proposing it.

### Modified Capabilities
None recorded in `openspec/specs/`. Note that `merchant-identity-resolution` and
`subscription-proposal-gate` are defined by the in-flight `dedupe-inbox-proposals-by-merchant`
change; `tracked-subscription-identity` extends that identity contract across the review boundary
into `subscriptions` and should be reconciled with those specs when both changes archive.

## Impact

- `supabase/functions/email-scan/index.ts` — `reviewCandidate` (1539): the staleness branch returns a
  warning outcome instead of calling `resolveCandidateForLifecycle`; accepts an acknowledgement flag
  that applies the confirmation; the created-subscription write (1653) takes the candidate's
  `canonical_merchant_key`. `resolveCandidateForLifecycle` (1914) is retained only for genuinely
  automatic resolution paths, not for a human's confirmation.
- `Renewa/SupabaseClient.swift`, `Renewa/Models.swift` — the decision response carries the warning
  reason and its text; the review request carries the acknowledgement.
- `Renewa/AppStore.swift` (484) — stop discarding the response; distinguish applied / warned /
  ignored; surface the warning and the failure.
- `Renewa/EmailScanView.swift` — `track()` and the review sheet handle the warned outcome; the
  optimistic collapse in `resolve()` must roll back on a warning, not treat it as done.
- `worker/src/agent/candidate-bridge.ts` — the tracked-subscription lookup must stop being empty in
  practice; matching cannot depend solely on a column no manual subscription ever sets.
- New Supabase migration — assign a canonical merchant identity on subscription creation, including
  the manual path.
- Depends on `restore-detected-event-identity`. Without keyed evidence the gate has nothing to
  reason about and would warn on everything.
