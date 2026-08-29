## ADDED Requirements

### Requirement: LLM decides which merchants surface

The scan engine SHALL determine whether an email account contains a paid subscription worth
surfacing using LLM judgment only. A cheap Tier-1 LLM triage classifies every message as `look` or
`skip`, and a single autonomous Tier-2 agent decides which merchants to propose. No hand-tuned
keyword score, numeric confidence threshold, or deterministic routing rule SHALL gate whether a
candidate surfaces.

#### Scenario: A billing email with no keyword match still surfaces

- **WHEN** an account contains a genuine paid-subscription receipt whose wording matches none of the
  legacy billing keywords
- **THEN** Tier-1 triage MAY still mark it `look`, the Tier-2 agent evaluates it, and it can be
  proposed as a candidate — its surfacing does not depend on any keyword or score

#### Scenario: Triage favors recall on ambiguity

- **WHEN** Tier-1 triage is uncertain whether a message relates to a subscription
- **THEN** the message is admitted (`look`) for the Tier-2 agent to judge, rather than dropped by a
  threshold

#### Scenario: Triage failure never drops mail silently

- **WHEN** the Tier-1 triage model errors or omits a message
- **THEN** that message is admitted wholesale (recall-only degradation), so an outage reduces
  efficiency but never correctness

### Requirement: The agent groups, judges recurrence, and reconciles autonomously

The Tier-2 agent SHALL group evidence into merchants itself, distinguish a recurring subscription
from repeated one-off purchases using its own judgment (informed by a `compute_cadence` perception
tool, not decided by it), and reconcile against the user's current subscriptions and prior
decisions before proposing. There SHALL be no per-merchant deterministic walk or cadence verdict
that overrides the model.

#### Scenario: Repeated one-off purchases are not proposed

- **WHEN** an account shows frequent but one-off purchases (e.g. ride receipts or food orders) with
  no membership or renewal signal
- **THEN** the agent declines to propose them as a subscription

#### Scenario: Already-tracked merchant is not re-proposed

- **WHEN** the user already tracks a merchant the agent finds evidence for
- **THEN** the agent reconciles instead of proposing a duplicate candidate

#### Scenario: Previously rejected merchant needs new evidence

- **WHEN** the user previously rejected or suppressed a merchant
- **THEN** the agent does not re-propose it absent materially new evidence

### Requirement: Human confirmation is preserved

The engine SHALL never add a subscription to the app directly. Every surfaced merchant SHALL be
written as a proposed candidate that a human confirms, edits, or rejects.

#### Scenario: Proposal awaits confirmation

- **WHEN** the agent proposes a subscription candidate
- **THEN** it appears in the user's review queue and is added to the app only after the user confirms

### Requirement: Guardrails bound the agent without judging subscriptions

The engine SHALL retain non-judgment guardrails around the nondeterministic agent: a tool authorizer
(read-only tools, scoped to message ids surfaced this run), a per-run budget (iterations, tool
calls, fetches, tokens, wall-clock) that guarantees termination, a strictly typed `propose` schema
with no free-text field (so untrusted email content cannot reach the human-facing card), and a
deterministic idempotency dedup on the write. These guardrails SHALL NOT decide whether something is
a subscription.

#### Scenario: Email content cannot inject instructions

- **WHEN** a fetched email body contains text resembling instructions
- **THEN** the agent treats it as untrusted data, and only typed, schema-validated fields can reach a
  proposal — no free-text passthrough

#### Scenario: The agent always terminates

- **WHEN** the agent would exceed its iteration, tool-call, fetch, token, or wall-clock budget
- **THEN** the run stops and returns whatever proposals it has, rather than looping unbounded

#### Scenario: A duplicate proposal is dropped by dedup

- **WHEN** the agent proposes a merchant whose canonical key already matches a tracked or suppressed
  subscription
- **THEN** the deterministic dedup guard drops the write (idempotency), independent of the agent's
  judgment

## REMOVED Requirements

### Requirement: Deterministic keyword prefilter and routing ladder decide candidates

**Reason**: Hand-tuned keyword scoring (`candidateSignalScore ≥ 2` / `isLikelyBillingCandidate`),
the `admitCandidate` threshold, and the fixed `routeAssessment` confidence ladder
(`minConfidence 0.35`) are the "manual filtering" this change removes; the include/withhold decision
moves entirely to the LLM.

**Migration**: The Tier-1 LLM triage replaces the keyword prefilter/admit gate, and the Tier-2
agent's own decision to call `propose` replaces the routing ladder. No configuration migration is
required for users; the endpoint contract is unchanged.
