## Context

The email scanner already uses extraction confidence, deterministic validation, merchant identity resolution, and lifecycle reconciliation before creating a `subscription_candidates` record. This is deliberately conservative: uncertain identity and lifecycle evidence is retained in evidence bundles and treated as non-actionable. The iOS Inbox page then shows only pending subscription candidates, and its review sheet is designed to confirm a concrete add, update, or cancellation.

This change introduces a middle path for ambiguity that is both meaningful and answerable by the account owner. It must retain the review-first and privacy-minimized posture: an AI question is not a subscription mutation, and it must not expose raw message content.

## Goals / Non-Goals

**Goals:**

- Let the scanner ask one concise, answerable question when a user response can resolve a material ambiguity.
- Keep the question in the primary Inbox flow, below connection/status context and above handled activity.
- Persist answers and associated evidence so future scans respect the user's decision.
- Convert an answer into an actionable subscription proposal only when the existing validation rules can support one.
- Keep uncertainty quiet when it is weak, stale, non-actionable, or cannot be resolved through a bounded answer.

**Non-Goals:**

- Automatically adding, modifying, canceling, or suppressing a subscription from a clarification response.
- Displaying raw email bodies, full sender addresses, or model chain-of-thought.
- Asking users to label arbitrary inbox messages or training a general-purpose model from their private email.
- Replacing the existing candidate confirmation sheet or the separate muted-services control.
- Supporting multiple simultaneous questions on the Inbox home screen.

## Decisions

### Use a first-class clarification request, not a `subscription_candidates` overload

Create durable clarification request and outcome records linked to the user, relevant evidence bundle, and optionally the supporting billing event. A request stores a typed `kind`, a compact question and explanation, a bounded answer set, priority, status, expiry, and minimal field context. Its answer is appended to an outcome/audit record.

The scanner's existing candidate model represents a concrete proposed subscription change and expects amount/currency/cycle validation. Reusing its `suggested_action = review` value would couple a simple question to the full subscription-edit form and make it too easy to treat an answer as confirmation. A first-class request preserves the semantic distinction and provides safe future extension.

Alternatives considered:

- **Reuse pending candidates:** fewer tables, but incorrect UX and mutation semantics.
- **Show all uncertain evidence in scan history:** maximally transparent but too noisy and does not collect structured answers.
- **Ask outside the app through a push notification only:** low visibility and no appropriate place to explain evidence or capture corrections.

### Restrict request creation to answerable, material ambiguity

The backend creates a request only when it has a concrete, privacy-safe evidence bundle and a response changes a downstream decision. Initial request kinds are:

- `lifecycle_check`: evidence suggests a recent paid service but lifecycle is uncertain; ask whether the service is still active.
- `identity_check`: a descriptor can plausibly map to one existing merchant, but deterministic resolution cannot safely assert the relationship.
- `billing_cycle_check`: the service identity and paid charge are credible but cycle is materially ambiguous.

The scanner MUST not create a request for generic low model confidence, marketing email, weak merchant identity, stale-only receipt evidence, or a question whose response would still be unable to produce a safe next step. Requests are deduplicated per user, merchant/evidence bundle, and kind while open; resolved or expired questions are not immediately re-asked unless materially newer evidence is found.

### Put one prioritized Quick question in the Inbox review area

The Inbox home exposes one request at a time under a shared **Needs your review** area. It appears below the status and connected-inbox chips, before handled activity. If a concrete candidate and a clarification are both pending, the clarification is prioritized only when its answer unlocks the candidate; otherwise the actionable candidate remains first. The card names itself **Quick question**, states the one missing fact, gives a short evidence explanation, and exposes 2–3 choices plus **Not sure** where applicable.

Tapping the card opens a focused detail sheet. It shows the question, a privacy-minimized evidence timeline, and the same answer choices. It does not present amount/currency/edit fields unless the request kind explicitly concerns that field.

Alternatives considered:

- **Separate Questions tab:** hides the request from the existing Inbox decision flow.
- **Modal alert immediately after scanning:** interrupts navigation and is easily dismissed without context.
- **Multiple cards on home:** conflicts with the quiet-assistant Inbox design.

### Answers record intent but do not mutate subscriptions directly

Responses transition the request atomically from open to answered, dismissed, or retained-uncertain and append the outcome. A duplicate submission returns the existing resolved state. Effects are deliberately constrained:

- A positive, sufficiently supported answer can create or unblock a normal pending subscription candidate; the person must still confirm that candidate through the existing review sheet.
- A negative answer can dismiss the request and, where the user explicitly selects a service-is-not-mine outcome, apply the existing merchant suppression policy.
- **Not sure** preserves the evidence as uncertain and removes the request from immediate attention without claiming a subscription state.
- Identity answers can create a user-scoped alias mapping only after the person explicitly confirms the relationship.

### Keep the API and stored evidence minimal

The status payload returns only request id, kind, question, compact explanation, answer labels, status, merchant label, and redacted/dated evidence items already permitted in the current learning UI. The request API never returns raw snippets, bodies, OAuth data, or model output. RLS limits all reads to the request owner; Function endpoints perform ownership checks before resolve operations.

## Risks / Trade-offs

- **Question fatigue** → one open home card, strict eligibility, deduplication, expiry, and a quiet **Not sure** path.
- **A user mistakes a question for a subscription change** → explicit copy that answers only help Renewa understand; a separate confirmation remains mandatory for changes.
- **Incorrect identity learning contaminates future scans** → alias mappings remain user-scoped, are auditable, and originate only from an explicit answer.
- **New evidence arrives while a question is open** → recompute/close stale requests transactionally before presenting a downstream candidate.
- **Sensitive email inference in the UI** → retain the existing privacy-minimized evidence limits and avoid full sender/message content.
- **Duplicate provider events create repeated questions** → unique open-request key plus idempotent resolution endpoints.

## Migration Plan

1. Add migration tables, constrained enums/status fields, owner RLS, indexes for open-request prioritization, and outcome audit records.
2. Deploy backend request creation, status serialization, and authenticated resolution endpoint/action.
3. Release the iOS model/state handling and the Inbox Quick question card/detail sheet behind the presence of a request payload.
4. Validate with redacted fixtures for eligible ambiguity, weak evidence, duplicate event, answer retry, and no-direct-mutation cases.
5. Monitor request volume, dismissal/not-sure rates, and post-answer confirmation rates before broadening request kinds.

Rollback hides clarification payloads and stops creating new requests. Existing requests and outcomes remain inert audit data; the existing candidate confirmation flow continues unchanged.

## Open Questions

- Should a `Not sure` request be eligible again only after newer evidence, or after a fixed cooldown as well?
- For an identity check, should **No** only dismiss the request or offer an optional “never suggest this descriptor again” path in the first release?
- What initial maximum age makes a receipt recent enough for a lifecycle question without reviving obsolete subscriptions?
