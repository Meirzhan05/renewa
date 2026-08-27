## ADDED Requirements

### Requirement: A single budgeted agent processes the look set
The system SHALL run one autonomous agent per scan over the emails triaged `look`. The agent SHALL
operate within a per-scan budget (iterations, tool calls, fetches, tokens, wall-clock) that
guarantees termination, and its run SHALL be checkpointed so it survives worker restarts.

#### Scenario: The run terminates within budget
- **WHEN** the agent has consumed its iteration, tool-call, fetch, token, or wall-clock budget
- **THEN** the agent stops and finalizes whatever proposals it has, rather than looping

#### Scenario: Single agent, not sharded
- **WHEN** a scan runs
- **THEN** one agent handles it end to end, with no supervisor or cross-agent merge layer

### Requirement: The agent reads through read-only tools only
The agent SHALL gather evidence only through read-only tools — `search_inbox` (metadata),
`fetch` (one sanitized body), `compute_cadence` (amount/interval/spread math over given messages),
`list_current_subscriptions`, and `list_prior_decisions`. No tool SHALL write, track, or send
outward except the human-gated `propose`. Fetched bodies SHALL be sanitized and truncated, and
email content SHALL be treated as untrusted data whose instructions are never followed.

#### Scenario: Read tools cannot mutate state
- **WHEN** the agent calls any read tool
- **THEN** no subscription, tracking, or outbound side effect occurs

#### Scenario: Fetch is bounded and sanitized
- **WHEN** the agent fetches a message body
- **THEN** the body is sanitized and truncated before entering the agent's context

### Requirement: The agent triages by searching the provider index
The agent SHALL narrow the inbox by issuing targeted searches rather than ingesting all mail into
context, SHALL fetch full bodies sparingly (fetch is the most expensive tool and is specifically
budget-capped), and SHALL default to incremental scanning — a full cold sweep once, then only mail
since the last scan.

#### Scenario: Fetch stays within its own cap
- **WHEN** the agent has reached its fetch budget
- **THEN** further fetch requests are refused and the agent reasons from what it already has

#### Scenario: Incremental steady state
- **WHEN** a scan runs after an initial cold sweep
- **THEN** the agent processes only emails received since the last scan, plus targeted reconcile searches

### Requirement: The agent owns all subscription judgment
The agent SHALL decide merchant grouping (emergent identity, no canonical-key function), whether a
merchant is a recurring subscription versus repeated one-off purchases, field completeness, and the
add / ask / drop outcome. `compute_cadence` output is evidence the agent MAY use; no deterministic
rule SHALL override the agent's recurrence or routing decision.

#### Scenario: Recurrence is the agent's call
- **WHEN** cadence evidence suggests one-off but the agent judges the merchant recurring on other evidence
- **THEN** the agent's decision stands; no deterministic guard overrides it

#### Scenario: Repeated one-off purchases are not proposed as subscriptions
- **WHEN** the agent sees frequent variable-amount ride or order receipts with no membership signal
- **THEN** the agent judges them one-off and does not propose them as a subscription

### Requirement: The agent reconciles against known state
Before proposing, the agent SHALL consult `list_current_subscriptions` and `list_prior_decisions`
(prior proposals and their confirm/reject/suppress outcomes, aliases, and learned priors) and SHALL
avoid re-proposing what the user already tracks or has rejected.

#### Scenario: Already-tracked merchant is reconciled, not duplicated
- **WHEN** the agent finds evidence for a merchant already in the subscription list
- **THEN** it reconciles (e.g. price/lifecycle change) instead of proposing a duplicate new subscription

#### Scenario: Previously rejected merchant is respected
- **WHEN** the agent finds a merchant the user rejected in a prior scan
- **THEN** the agent does not re-propose it absent materially new evidence
