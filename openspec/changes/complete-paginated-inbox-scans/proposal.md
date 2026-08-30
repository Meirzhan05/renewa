## Why

A full inbox backfill creates up to 30 worker jobs for one scan run. The first worker job currently
marks that shared run complete, even though later pages are still queued. Inbox therefore tells the
person that the scan has stopped while the terminal shows the worker continuing for the remaining
pages. The iOS client also stops its status polling after roughly four minutes, which is shorter
than a realistic multi-page worker scan.

## What Changes

- Treat an inbox scan as complete only after every mailbox-page job and worker job belonging to its
  run has reached a terminal state.
- Decouple candidate persistence from finalizing `email_scan_runs`; a worker page can publish
  review candidates without ending the scan.
- Aggregate scan status from all page and worker jobs for each run, preserving active status while
  any work remains and surfacing partial or failed outcomes honestly.
- Keep the Inbox client synchronized with active long-running scans through sustained, paced polling
  and foreground resumption rather than a fixed four-minute cutoff.
- Add lifecycle coverage for a multi-page scan, including a completed first page with later worker
  pages still pending.

## Capabilities

### New Capabilities
- `paginated-inbox-scan-lifecycle`: Defines durable completion and app-visible progress semantics
  for a scan whose mailbox work is split across multiple edge and worker jobs.

### Modified Capabilities
<!-- none -->

## Impact

- **Worker:** candidate bridge and durable job-store completion coordination in `worker/src/agent/`
  and `worker/src/db.ts`.
- **Edge Function:** `email-scan` status derivation must aggregate all jobs associated with a run.
- **iOS:** `AppStore` polling lifecycle and Inbox active-state presentation.
- **Tests:** worker unit tests, pure edge status tests, XCTest polling/presentation coverage, plus a
  hosted end-to-end verification with a multi-page mailbox.
- **Operations:** deploy the updated `email-scan` Function and worker against the same Postgres;
  no intentional public API contract change or destructive data migration is required.
