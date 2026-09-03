## 1. Prerequisite

- [x] 1.1 Confirm `restore-detected-event-identity` is deployed and that
      `detected_billing_events` rows written by recent scans carry a `canonical_merchant_key`.
      Without keyed evidence, a contradiction test finds nothing to contradict and this change
      silently degrades to "always apply".

## 2. Server: the gate becomes advisory

- [x] 2.1 In `supabase/functions/email-scan/index.ts`, replace the `stale` branch of
      `reviewCandidate` (1597-1611) with a warned outcome: leave `review_status = 'pending'`, create
      nothing, and return a stable reason code plus human-readable text. Stop calling
      `resolveCandidateForLifecycle` from the human confirmation path; leave the function in place
      for automatic reconciliation.
- [x] 2.2 Accept an acknowledgement field on the review request. When present with a confirm
      decision, skip the warning and apply. Acknowledgement must not bypass
      `candidateConfirmationIssues` — a missing amount still fails as a validation error.
- [x] 2.3 Rework the staleness test from absence to contradiction: build the lifecycle picture from
      the evidence records **plus** the candidate's merged fields **plus** the submitted edits, and
      warn only when stored evidence contradicts the decision (e.g. a cancellation more recent than
      any renewal), never merely because an event row lacked a field the card or the user supplied.
- [x] 2.4 Compose warning text from typed fields and fixed copy only, preserving the anti-exfiltration
      boundary. Attribute a suppression warning to the user's own earlier choice rather than to
      missing evidence.
- [x] 2.5 Unit-test the outcomes in `supabase/functions/email-scan/email-discovery.test.ts`: a
      current merchant applies; a cancelled merchant warns; the same request with an acknowledgement
      applies; a card completed by merged fields does not warn; a card completed by user edits does
      not warn; an acknowledged but invalid confirmation still fails validation.

## 3. Server: identity crosses the review boundary

- [x] 3.1 Change the created/updated subscription write (1653-1692) to take the candidate's
      `canonical_merchant_key` rather than `canonicalMerchantKey(merchantName)`, so a renamed card
      keeps its identity.
- [x] 3.2 Work out what that does to `source_key` (`email:${key}`), which is the conflict target of
      the confirm upsert. Ensure existing email-sourced subscriptions still resolve to the same row;
      do not orphan them into duplicates.
- [x] 3.3 Derive identity at the point of use instead of storing it on every row (no migration; see
      design). In `worker/src/agent/candidate-bridge.ts`, select `name` alongside
      `canonical_merchant_key`, drop the `is not null` filter, and fall back to
      `canonicalMerchantKey(name)` when the column is unset.
- [x] 3.4 Do the same in `listCurrentSubscriptions` (`worker/src/agent/reconcile-db.ts:52`), which
      filters the same way — so the agent is told about manually added subscriptions when it decides
      what to propose, not just at the write boundary.
- [x] 3.5 Test that a confirmed subscription is matched by a later proposal from the same sender
      domain, that a subscription with no stored key is matched by its name, and that two genuinely
      distinct vendors are never fused.

## 4. Client: stop reporting refusals as saves

- [x] 4.1 Extend `EmailCandidateDecisionResponse` in `Renewa/Models.swift` with the warning reason
      and text, and the review request in `Renewa/SupabaseClient.swift` with the acknowledgement.
      Decode an unrecognized outcome as not-applied, never as success.
- [x] 4.2 Change `AppStore.reviewEmailCandidate` (484) to consume the response instead of discarding
      it at 498, returning a typed outcome — applied / warned / ignored / idempotent / failed —
      rather than a `Bool` derived from "nothing was thrown".
- [x] 4.3 In `Renewa/EmailScanView.swift`, make `resolve(_:_:)` roll the optimistic collapse back on
      any outcome that is not applied, and keep it collapsed on applied or idempotent.
- [x] 4.4 Surface a warning in the flow it came from: `track()`'s one-tap path and the review sheet
      both present the reason and offer to proceed; proceeding re-submits with the acknowledgement.
- [x] 4.5 Distinguish a transport or auth failure from a server-side refusal in what the user is
      shown; the existing error alert is for the former.
- [x] 4.6 Add the warned state to `RenewaPreviewFixture.InboxScenario` and a `#Preview`, so the
      warning UI is inspectable without a live inbox.

## 5. Verify against the real inbox

- [ ] 5.1 Confirm a healthy card in one tap; verify the subscription appears on Home and the card
      reaches `confirmed` with a non-null `applied_subscription_id`.
- [ ] 5.2 Confirm a card whose merchant has a later cancellation; verify the warning appears, the
      card stays pending on decline, and applies on acknowledgement.
- [ ] 5.3 Confirm the previously stuck `OpenAI (ChatGPT Plus)` card by supplying the missing amount
      in the review sheet; verify it applies rather than being refused for the field just typed.
- [ ] 5.4 Run a scan after a confirmation and verify the confirmed subscription is not re-offered as
      a new add.
- [ ] 5.5 Add a subscription by hand, run a scan, and verify the agent does not propose it.
- [x] 5.6 Check the deployed iOS build against the new server outcomes before deploying the server
      change, so an older client cannot read the warned outcome as a success.
