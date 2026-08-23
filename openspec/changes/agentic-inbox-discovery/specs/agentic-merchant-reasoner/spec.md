## ADDED Requirements

### Requirement: Per-merchant agentic reasoning loop

The system SHALL run a tier-2 reasoning loop once per candidate merchant over that
merchant's evidence bundle. Within a bounded budget the loop MAY iterate: assess the
current evidence, optionally invoke a read-only tool to gather more, incorporate the
result, and re-assess, until it is confident or its budget is exhausted. The loop SHALL
emit exactly one structured assessment per merchant.

#### Scenario: Under-confident loop gathers more evidence then concludes
- **WHEN** the initial bundle for a merchant is insufficient to decide and budget remains
- **THEN** the loop SHALL invoke a permitted tool to gather more evidence, re-assess, and
  emit a single assessment for that merchant

#### Scenario: Sufficient evidence concludes without tool calls
- **WHEN** the initial bundle already supports a confident assessment
- **THEN** the loop SHALL emit its assessment without invoking any tool

### Requirement: Read-only, scoped tool surface

The loop's only tools SHALL be read-only and limited to `search_inbox(query)`,
`fetch(message_id)`, and `get_more(sender)`. Every tool call SHALL be scoped to the current
user's connected inbox and the merchant under consideration: `search_inbox` SHALL NOT reach
outside the current connection, `get_more` SHALL be restricted to sender domains associated
with the merchant, and `fetch` SHALL be restricted to message IDs surfaced within the
current scan. Tool arguments SHALL be validated against these scopes before execution and
rejected otherwise. The loop SHALL NOT have any tool that mutates state, tracks a
subscription, or sends data to a third party.

#### Scenario: Out-of-scope fetch is rejected
- **WHEN** the loop requests `fetch` for a message ID not surfaced within the current scan
- **THEN** the tool call SHALL be rejected and SHALL NOT return message content

#### Scenario: get_more is confined to the merchant's senders
- **WHEN** the loop calls `get_more(sender)` with a sender domain unrelated to the merchant
- **THEN** the call SHALL be rejected

### Requirement: Hard budget envelope and guaranteed termination

Each per-merchant loop SHALL enforce hard caps on iterations, tool calls, fetched messages,
and tokens, plus a wall-clock timeout. The scan SHALL additionally enforce a per-run cap on
the number of merchants reasoned over and a global token/cost budget that fits the
edge-function execution limits. The loop SHALL always terminate at its budget; on exhaustion
it SHALL emit a best-effort assessment carrying reduced confidence rather than looping
further.

#### Scenario: Budget exhaustion yields a low-confidence result, not a hang
- **WHEN** a merchant loop reaches its iteration, tool-call, or time budget before becoming
  confident
- **THEN** it SHALL stop and emit a best-effort assessment with reduced confidence

#### Scenario: Per-run merchant cap bounds a large inbox
- **WHEN** a scan produces more candidate merchants than the per-run cap
- **THEN** reasoning SHALL be bounded to the cap and remaining merchants SHALL be deferred
  to a continuation rather than exceeding the run budget

### Requirement: Untrusted-data discipline inside the loop

Email content supplied to the loop SHALL be treated as untrusted data. The loop SHALL NOT
follow instructions contained in email content, SHALL NOT let email content widen its tool
scope or budget, and SHALL ignore any in-content directive to fetch, send, or act. A
prompt-injection attempt in an email SHALL at worst waste bounded budget or yield a proposal
that a human can reject; it SHALL NOT cause state mutation or out-of-scope access.

#### Scenario: Injection in email content cannot escalate
- **WHEN** an email in the bundle contains text instructing the agent to search unrelated
  mail or take an action
- **THEN** the loop SHALL ignore the instruction, stay within its scoped tools and budget,
  and take no action beyond emitting an assessment

### Requirement: Structured, grounded assessment output

The loop SHALL emit a structured assessment per merchant containing: an existence confidence
(is this an active paid subscription), a completeness indicator with the list of missing
fields, the extracted fields it does support (amount, currency, billing cycle, renewal date,
category as available), references to the specific evidence that supports each asserted
field, and an abstain reason when it declines. Monetary amounts SHALL never be invented;
an amount SHALL be asserted only when grounded in evidence.

#### Scenario: Assessment reports what is missing rather than dropping the merchant
- **WHEN** the loop establishes a paid subscription but cannot determine the billing cycle
- **THEN** its assessment SHALL mark existence high, completeness incomplete, and list
  `billing_cycle` among the missing fields, with evidence refs for the fields it does assert

#### Scenario: Ungrounded amount is not emitted
- **WHEN** the loop cannot find evidence of a concrete amount
- **THEN** it SHALL leave the amount unset rather than infer one
