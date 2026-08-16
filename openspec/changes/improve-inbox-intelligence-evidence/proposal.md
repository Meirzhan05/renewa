## Why

Inbox Intelligence extracts useful billing events, but it still makes discovery decisions one email at a time. Merchant aliases, payment-processor senders, stale receipts, and ambiguous corrections can produce duplicate, outdated, or unconvincing proposals. The product now needs to reason from a bounded body of evidence for a merchant and measure whether its recommendations earn user trust.

## What Changes

- Assemble normalized email events into merchant-level evidence bundles before creating, updating, withdrawing, or explaining a subscription proposal.
- Strengthen deterministic merchant identity resolution using sender-domain and reviewed alias evidence, while preserving ambiguity rather than guessing a match.
- Add a narrowly scoped, no-tools AI adjudication pass for explicitly defined identity or evidence conflicts only; it returns an explanation or abstains and has no data-mutation authority.
- Make review feedback first-class: retain whether a proposal was confirmed, edited, ignored, suppressed, or contradicted, with non-sensitive correction reasons where a user supplies them.
- Add privacy-minimized quality telemetry and a redacted evaluation corpus to measure precision, field accuracy, stale-proposal rate, correction rate, latency, and model cost by model/prompt version.
- Improve the review experience to show a compact evidence timeline and clear reasons for a proposal, an abstention, or a withheld suggestion.
- Preserve the existing review-first boundary. This change does not add mail write permissions, email-body retention, general mailbox chat, model tools, autonomous subscription changes, or a multi-agent system with independent authority.

## Capabilities

### New Capabilities

- `inbox-intelligence-evaluation`: Measure discovery quality from redacted fixtures and user-review outcomes without retaining raw email content.
- `merchant-evidence-resolution`: Assemble merchant-local billing evidence, resolve supported aliases deterministically, and represent ambiguous identity or lifecycle evidence without guessing.

### Modified Capabilities

- `ai-email-subscription-discovery`: Produce candidates from merchant-level evidence and invoke constrained adjudication only for defined ambiguities.
- `billing-event-review`: Show understandable evidence and capture review outcomes and corrections for quality measurement.
- `subscription-lifecycle-reconciliation`: Base current, ended, and uncertain outcomes on evidence bundles with explicit identity confidence and conflict handling.

## Impact

- Affects the shared email-discovery types and reducer, the `email-scan` Edge Function, discovery migrations, and the Inbox Intelligence review UI/state/models.
- Adds user-owned, privacy-minimized evidence and feedback metadata plus indexes for merchant-local lookup; raw message bodies and raw model payloads remain transient.
- Adds a constrained DeepSeek-compatible adjudication adapter for rare ambiguity cases, versioned prompt/model telemetry, and a fixture-driven backend evaluation suite.
- Requires product decisions on which feedback reasons are optional, how long non-sensitive outcome telemetry is retained, and which measured thresholds must be met before any future automation is considered.
