## ADDED Requirements

### Requirement: Narrowing what is fetched SHALL NOT reduce discovery recall
Any change that causes the scan to fetch fewer messages than the unfiltered window — a provider-side
query, a category restriction, a keyword filter, a shortened lookback — SHALL be justified by a
measurement against the unfiltered baseline showing it does not lose subscriptions the system would
otherwise have found. Quota cost, scan duration, and rate-limit avoidance SHALL NOT by themselves
justify a narrowing.

The asymmetry is the reason: a scan that stops is visible and the user can retry it, while a
subscription that was never fetched is invisible to everyone — the user, the agent, and the logs.
Trading the first failure for the second makes the product quietly worse while appearing to fix it.

#### Scenario: A proposed filter is measured before adoption
- **WHEN** a provider-side filter is proposed to reduce how many messages a scan fetches
- **THEN** its recall against the unfiltered baseline is measured on real mail before it is adopted

#### Scenario: A filter that loses a detection is not adopted as a hard filter
- **WHEN** a candidate filter would have excluded a message that produced a billing event
- **THEN** it is not adopted as a hard filter, regardless of how much quota it would save

#### Scenario: Quota pressure alone does not justify narrowing
- **WHEN** scans are failing on provider rate limits
- **THEN** narrowing what is fetched is chosen only with recall evidence; otherwise the response is
  to fetch more slowly rather than to fetch less

### Requirement: Prefer prioritization over exclusion when recall is uncertain
Where a narrowing would improve cost but its effect on recall is uncertain or unmeasured, the scan
SHALL prefer to reorder work rather than to drop it — fetching the likely-relevant set first and the
remainder as budget allows. Exclusion SHALL be reserved for filters whose recall has been measured.

#### Scenario: An uncertain filter reorders rather than excludes
- **WHEN** a candidate filter shows a large cost saving but its recall is not established
- **THEN** it is used to order fetching, and messages outside it are still fetched when budget allows

#### Scenario: A budget-exhausted scan reports what it did not reach
- **WHEN** a prioritized scan runs out of budget before fetching every message in the window
- **THEN** the run records that the window was not fully covered, rather than presenting itself as
  complete

### Requirement: A filter's continued fitness SHALL remain observable
A provider-side filter depends on classification the provider controls and can change without
notice. Where the system relies on such a filter, it SHALL retain a means of detecting that the
filter has begun excluding relevant mail — a periodic unfiltered comparison, sampling outside the
filter, or an equivalent check. Adopting a filter and never looking again SHALL NOT be treated as
sufficient.

#### Scenario: Drift is detectable after adoption
- **WHEN** a provider-side filter has been in use for some time
- **THEN** a mechanism exists that would reveal it now excluding mail the system should have found

#### Scenario: A measurement is recorded with what it was measured against
- **WHEN** a filter's recall is measured
- **THEN** the mailbox, window, and date of the measurement are recorded alongside the result, so a
  later reader can judge whether it still applies
