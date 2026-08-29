## ADDED Requirements

### Requirement: The agent reads full message bodies on demand

The scan worker's `fetch` tool SHALL return the **sanitized full body** of a message, retrieved from
the connected mail provider on demand, so the autonomous agent judges a subscription from complete
evidence rather than a truncated snippet. Full-body retrieval SHALL occur **only** for messages the
agent explicitly fetches (not for the whole window and not during metadata search). When a full body
cannot be retrieved — no stored credential, an expired or invalid credential, an unsupported provider,
or a provider error — the tool SHALL fall back to the message snippet rather than failing the tool
call or the scan.

#### Scenario: A body-only receipt is fetched with its full body

- **WHEN** the agent calls `fetch` on a message whose amount and renewal terms live in the body (e.g.
  a Stripe receipt) and a valid Google credential is available for the scan
- **THEN** the tool returns the message's sanitized full body, so the agent can assert the amount,
  billing cycle, and recurrence it could not see from the snippet alone

#### Scenario: Missing or expired credential degrades to the snippet

- **WHEN** the agent calls `fetch` but no usable credential is available (absent, expired, wrong
  provider) or the provider read fails
- **THEN** the tool returns the message snippet as the body and the scan continues normally, never
  erroring out

#### Scenario: Metadata search is unaffected

- **WHEN** the agent calls `search_inbox`
- **THEN** it is matched against the already-fetched window metadata only, with no full-body retrieval

### Requirement: An enqueued scan carries the credential needed for body retrieval

When the edge function enqueues a worker scan for a Google connection, it SHALL persist the
connection's access token on the scan job so the worker can perform on-demand body reads. This uses
the existing `scan_jobs.access_token` column and does not change the scan request/response contract.

#### Scenario: Enqueue stores the access token

- **WHEN** the edge hands a Google mailbox window off to the worker queue
- **THEN** the enqueued `scan_jobs` row includes the connection's access token, so the worker can read
  full message bodies for that scan

#### Scenario: A token-less job still runs

- **WHEN** the worker claims a scan job that has no stored access token (a legacy or non-Google job)
- **THEN** it runs the scan using the snippet fallback for `fetch`, without error
