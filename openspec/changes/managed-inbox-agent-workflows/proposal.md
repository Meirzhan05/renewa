## Why

Inbox agent execution currently depends on a locally started Node worker polling Postgres. That
cannot serve concurrent App Store users reliably: it has no production deployment, fair scheduling,
lease recovery, or capacity control, and a stopped worker can leave work appearing active forever.

## What Changes

- Replace the developer-operated polling worker with a managed, durable inbox-agent workflow
  runtime that runs in production and scales concurrent page analyses within explicit limits.
- Model every agent page as an idempotent, observable work item with a lease, heartbeat, retry
  policy, cancellation boundary, and terminal error handling.
- Enforce global, provider-specific, and per-user concurrency limits so simultaneous users make
  progress fairly without overloading mail or model providers.
- Keep Supabase as the source of truth for scan runs, review candidates, and app-visible progress;
  the iOS app will never start or operate background agents.
- Stop putting provider access tokens in generic worker-job payloads; managed tasks retrieve the
  needed credential through the server-side credential path.

## Capabilities

### New Capabilities

- `managed-inbox-agent-execution`: Durable, horizontally scalable execution, recovery, fairness,
  and observability rules for inbox agent work.
- `inbox-agent-workflow-orchestration`: End-to-end orchestration rules from a user scan request
  through paginated page analysis, cancellation, and terminal completion.

### Modified Capabilities

<!-- None. Existing orchestration artifacts are change-local rather than main specifications. -->

## Impact

- **Backend:** replace the local `worker/` polling entry point with managed task definitions and a
  production deployment integration; add durable task metadata and secure credential retrieval.
- **Database:** add job lease/heartbeat, idempotency, cancellation, retry, and operational-trace
  fields or their managed-runtime mappings while preserving the run completion coordinator.
- **Edge Function:** enqueue and observe managed tasks rather than depending on a developer's
  process; retain owner-scoped API responses.
- **iOS:** present user-safe queued/running/cancelled/terminal scan progress sourced from scan runs,
  without exposing internal queue IDs.
- **Operations:** provision the selected managed task platform, its secrets, concurrency controls,
  alerts, dashboards, load tests, and a staged rollout plan.
