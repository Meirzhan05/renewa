## Context

The current discovery worker retrieves bounded likely billing messages, extracts one structured event per message, normalizes the reported merchant name, and applies a deterministic lifecycle reducer over events with the same canonical merchant key. It requires user review before any subscription change, and it does not retain raw email bodies or model responses.

That pipeline is safe but loses important context: one merchant can arrive under multiple aliases or sender domains, and a single event does not communicate the evidence behind a proposal. Confirmation and edits also do not form an explicit quality dataset. The change must improve precision and explainability without creating a general-purpose mailbox agent or adding a new mail-data retention boundary.

## Goals / Non-Goals

**Goals:**

- Build bounded merchant-level evidence bundles from immutable extracted events.
- Resolve supported merchant aliases deterministically; preserve ambiguity rather than guessing.
- Permit a tightly constrained, advisory adjudication request only for identity/evidence conflicts that deterministic rules cannot resolve.
- Link each actionable proposal to its supporting event set and display a privacy-minimized explanation.
- Record structured review outcomes and evaluate quality over a redacted fixture corpus.

**Non-Goals:**

- Retaining raw email content or raw model input/output.
- Giving a model tools, direct database access, subscription identifiers, or authority to mutate data.
- Automatic subscription creation, cancellation, or update.
- General mailbox chat, attachment processing, broadening OAuth scopes, or a multi-agent runtime.

## Decisions

### Resolve identity before lifecycle

The worker will map each extracted event to a merchant evidence key before it invokes lifecycle reconciliation. A deterministic resolver first considers the event's canonical merchant key, a registered reviewed alias, a recognized brand, and an exact verified sender domain. It returns `resolved`, `ambiguous`, or `unresolved`; only resolved events join a merchant bundle.

Reviewed aliases are user-owned mappings created from confirmed or explicitly corrected reviews, not from arbitrary model output. A relationship table will link a bundle/proposal to its event IDs so the immutable source event remains authoritative. This is preferred to overwriting historical event keys because new evidence and later corrections must not rewrite the past.

### Treat an evidence bundle as the proposal input

The lifecycle reducer will operate on resolved event sets ordered by source-received time. A candidate is created only when the bundle's latest supported lifecycle outcome is current or an explicit ending applies to exactly one active subscription. The candidate stores its supporting event links and a short system-generated reason; it does not duplicate message content.

Ambiguous and unresolved events are retained as validated facts but do not create an action candidate. The UI can report that discovery withheld a suggestion because identity or lifecycle evidence was insufficient. This precision bias is preferable to asking a person to clean up false subscriptions.

### Use a bounded advisory adjudicator for exceptional conflicts

The worker may call a separate DeepSeek-compatible adjudication adapter only after the deterministic resolver identifies a named ambiguity, such as competing aliases sharing a verified sender domain. Its input is a small, sanitized event-summary bundle: normalized merchant labels, sender domains, dates, event types, currencies, and existing non-sensitive evidence summaries. It excludes raw bodies, raw headers, subscription IDs, and free-form instructions from email.

The adapter returns a versioned JSON decision of `same_merchant`, `different_merchant`, or `abstain`, plus a compact explanation. Runtime validation verifies the schema and that every referenced evidence key was submitted. The result can only select a server-owned evidence-resolution path; it cannot create a candidate by itself, bypass lifecycle policy, or mutate a subscription. No retry is attempted for an abstention or invalid output.

This limited second stage is chosen over a multi-agent pipeline because the unresolved problem is a bounded classification task. Multiple autonomous agents would add latency, privacy exposure, and non-deterministic disagreements without adding a safe new authority boundary.

### Capture review outcomes without retaining mail data

Confirmation, ignore, suppression, cancellation confirmation, and field edits will create a user-owned outcome record. The record references the candidate and event links, records the requested and applied action, and stores only normalized before/after subscription fields plus an optional standardized correction reason. A confirmation can promote a user-reviewed alias when the corrected merchant identity is valid and unambiguous.

The outcome record is an audit/evaluation input, not a training pipeline. It remains protected by RLS and follows the account-deletion cascade.

### Evaluate before tuning or automating

A redacted, synthetic/consented fixture corpus will cover recurring receipts, one-time purchases, trials, cancellations, price changes, merchant aliases, payment processors, non-English mail, marketing, and prompt-injection text. Tests will evaluate deterministic selection, extractor/adjudicator schema validation, bundle/lifecycle outcomes, and candidate eligibility.

Production telemetry will contain only counts, versions, latency/cost bands, resolution outcomes, and user-review outcomes. Dashboards and threshold decisions will use measured precision, edit rate, false-suggestion rate, abstention rate, and end-to-end scan latency. No change in this proposal authorizes automatic application based on those metrics.

## Risks / Trade-offs

- [A legitimate merchant has no recognized alias] → Retain the event and abstain from proposing an action; let a later explicit review create a verified alias.
- [A model incorrectly merges two merchants] → Require an eligible deterministic ambiguity, validate the bounded output, retain the adjudication audit, and still require lifecycle policy and user confirmation.
- [Evidence links increase storage/query complexity] → Store IDs and short typed reasons only, index by user/bundle/candidate, and keep events immutable.
- [Feedback captures sensitive free text] → Use optional standardized reason codes rather than unrestricted notes.
- [Additional model calls increase cost or latency] → Invoke adjudication only for bounded conflict types, with no retries and explicit telemetry.
- [Fixture results overstate production quality] → Segment metrics by provider/language/event type and use user-review corrections as a separate production signal.

## Migration Plan

1. Add additive, user-owned tables/columns for evidence bundles or event links, reviewed aliases, advisory adjudications, and review outcomes; enable RLS and account-deletion cascades.
2. Deploy pure resolver/bundle logic and tests with adjudication disabled by configuration.
3. Deploy the worker to create bundle-backed candidates and the client to show evidence explanations and correction reasons.
4. Enable the advisory adjudicator for a small set of named ambiguity types and observe telemetry; it can be disabled without removing stored facts or review controls.
5. Roll back by disabling bundle candidate generation/adjudication. Existing events, candidates, and audit metadata remain additive and recoverable.

## Open Questions

- Which standardized correction reasons are useful without making review cumbersome?
- What sender-domain verification rule is reliable enough to participate in deterministic identity resolution?
- Should withheld ambiguous evidence be visible in the Inbox screen, a history screen, or only as an aggregate scan explanation?
- What minimum measured precision and edit-rate targets must hold before expanding the adjudicator's allowed ambiguity types?
