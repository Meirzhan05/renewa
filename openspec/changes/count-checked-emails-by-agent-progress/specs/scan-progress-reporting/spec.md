## ADDED Requirements

### Requirement: "Emails checked" counts emails the agents have processed

The app-visible "emails checked" progress for a scan run SHALL count emails in pages the analysis agents have finished processing, not emails merely fetched and enqueued by the fetcher. The value SHALL be derived as the sum of `scan_jobs.message_count` over that run's pages whose status is `completed`.

#### Scenario: Counter climbs with agent progress, not fetch progress

- **WHEN** a run's pages have all been enqueued (each `scan_jobs` row created with its window size) but only some pages have been processed
- **THEN** the reported "emails checked" equals the summed window size of the `completed` pages only, so it climbs as pages finish rather than jumping to the full enqueued total

#### Scenario: Pending and running pages are not yet counted

- **WHEN** pages are still `pending` or `running`
- **THEN** their emails are not included in "emails checked" until their page reaches `completed`

### Requirement: Persisted run total matches the live counter

When a run reaches a terminal state, the `messages_scanned` value denormalized onto `email_scan_runs` SHALL be derived with the same completed-only rule as the live progress endpoint, so history and the live counter never disagree.

#### Scenario: All pages completed

- **WHEN** every page of a run completes successfully and the run finalizes
- **THEN** the persisted `messages_scanned` equals the full inbox size (sum over all completed pages)

#### Scenario: Some pages failed

- **WHEN** a run finalizes with one or more failed pages
- **THEN** the persisted `messages_scanned` counts only the completed pages, honestly reporting fewer than the full enqueued inbox size rather than a total that was never checked
