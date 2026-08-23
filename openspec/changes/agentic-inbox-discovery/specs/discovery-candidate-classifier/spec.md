## ADDED Requirements

### Requirement: Wide subscription-relevance classification

The system SHALL classify every fetched inbox message for subscription-relevance using a
tier-1 classifier model, and SHALL use that classification — not the keyword-only score —
as the gate that admits a message into merchant grouping and downstream reasoning. The
keyword signal MAY contribute as one input, but SHALL NOT by itself exclude a message the
classifier marks relevant.

#### Scenario: Terse receipt with a weak keyword score is still admitted
- **WHEN** a fetched message would score below the legacy keyword threshold but the tier-1
  classifier marks it subscription-relevant with sufficient confidence
- **THEN** the message SHALL be admitted into merchant grouping and reasoning rather than
  silently dropped

#### Scenario: Obvious marketing is excluded
- **WHEN** the classifier marks a message as not subscription-relevant (e.g. a promotional
  newsletter with no billing evidence)
- **THEN** the message SHALL NOT be admitted for per-merchant reasoning

### Requirement: Classifier output shape and merchant grouping

For each classified message the system SHALL produce a subscription-relevance decision, a
relevance confidence in [0,1], a best-guess merchant label, and a rank score. The system
SHALL group admitted messages by their resolved merchant so that all evidence about one
merchant is reasoned over together.

#### Scenario: Two emails about one merchant are grouped
- **WHEN** a welcome email and a receipt from the same merchant are both admitted
- **THEN** they SHALL be placed in the same merchant evidence bundle for reasoning

### Requirement: Tier-1 privacy and cost bounds

The tier-1 classifier SHALL operate only on message metadata and snippet (subject, sender,
snippet, received date) and SHALL NOT be sent full message bodies. Classification SHALL run
within a per-run cost/token budget and SHALL batch messages to stay within provider limits.

#### Scenario: Full bodies are never sent to tier-1
- **WHEN** the classifier evaluates a fetched message
- **THEN** only its metadata and snippet SHALL be included in the classifier request, never
  the full sanitized body

### Requirement: Classifier degradation is safe

If the tier-1 classifier is unavailable, errors, or returns an unparseable result for a
message, the system SHALL fall back to the deterministic keyword signal for that message so
that a classifier outage degrades recall gracefully rather than aborting the scan.

#### Scenario: Classifier outage falls back to keyword gate
- **WHEN** the tier-1 classifier call fails for a batch
- **THEN** the affected messages SHALL be gated by the deterministic keyword score and the
  scan SHALL continue
