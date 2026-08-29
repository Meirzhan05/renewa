## ADDED Requirements

### Requirement: The app triggers scans through the worker queue

The app's scan trigger SHALL enqueue a scan for the persistent worker rather than run discovery
inline in the edge function. The `POST /functions/v1/email-scan` endpoint contract (start / status)
SHALL be preserved so the iOS app is unchanged, but `start` SHALL create a queued `scan_jobs` row
that the worker claims.

#### Scenario: Starting a scan enqueues a job

- **WHEN** the app calls the scan endpoint with `action: "start"`
- **THEN** a `scan_jobs` row is created for the user and the endpoint returns a scan/run status the
  app can poll — no discovery runs inside the edge function

#### Scenario: iOS app is unchanged

- **WHEN** the app starts a scan and later reads candidates
- **THEN** it uses the same endpoint and the same `subscription_candidates` review queue as before,
  unaware that a worker now performs the discovery

### Requirement: The worker runs the autonomous funnel as the live path

The persistent worker SHALL claim queued scan jobs and run the autonomous two-tier funnel
(`AGENT_MODE=autonomous`) as the sole discovery path. The legacy per-merchant graph and the
edge-function discovery paths SHALL no longer perform live scans.

#### Scenario: Worker claims and runs a job

- **WHEN** a `scan_jobs` row is queued
- **THEN** the worker claims it, fetches the user's inbox, runs Tier-1 triage and the Tier-2 agent,
  and records the run's outcome

#### Scenario: Only one live discovery path exists

- **WHEN** discovery runs for any user
- **THEN** it runs through the worker's autonomous funnel; the deterministic edge-function pipeline
  is not invoked

### Requirement: The worker reads the account and reconciles against real app data

The worker SHALL fetch the user's mail through their stored provider OAuth tokens (not a fixed
scan-window stub), and its reconcile readers SHALL be bound to the real app data — current
subscriptions, learned merchant priors, suppressions, and reviewed aliases — so proposals reflect
what the user already tracks and has decided.

#### Scenario: Reconcile uses live subscriptions and prior decisions

- **WHEN** the agent reconciles before proposing
- **THEN** it reads the user's actual tracked subscriptions and prior review decisions from the app
  database, not empty in-memory stubs

#### Scenario: Provider read is scoped and read-only

- **WHEN** the worker fetches inbox messages
- **THEN** it uses the user's stored OAuth tokens with read-only access and never writes to the
  provider account

### Requirement: Agent proposals bridge into the app review queue

Proposals the worker records (as `scan_outcomes` of kind `present`) SHALL be bridged into the app's
`subscription_candidates` table so the existing iOS review UI surfaces them unchanged, and the scan
run's status SHALL be readable by the app.

#### Scenario: A proposal becomes a review-queue candidate

- **WHEN** the worker records a `present` outcome for a merchant
- **THEN** a corresponding `subscription_candidates` row is created (respecting suppression and
  duplicate-tracking rules) and appears in the app's review queue

#### Scenario: Scan status is readable

- **WHEN** the app polls scan status after enqueueing
- **THEN** it can observe the run progressing and completing, including a count of surfaced
  candidates

## REMOVED Requirements

### Requirement: Discovery runs inside the ephemeral edge function

**Reason**: The edge function's inline discovery (both the legacy per-message extractor and the
flag-gated in-edge agentic path) is replaced by the persistent worker; the edge function is reduced
to an enqueue + status/read shim.

**Migration**: `runAgenticDiscovery` and the legacy per-message extraction branch are removed from
`email-scan/index.ts`; the endpoint now enqueues a `scan_jobs` row and returns/reads status. No
client migration is required — the endpoint path and response contract are preserved.
