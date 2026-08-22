## 1. Latest-check presentation

- [x] 1.1 Audit the existing durable scan-status fields and add a presentation helper for the latest completed provider/inbox label, timestamp, outcome, and optional truthful counts.
- [x] 1.2 Refine the Inbox Intelligence header subtitle to orient people to subscription activity from their connected inboxes without repeating the monitoring state.
- [x] 1.3 Add the compact Latest check card below the current-state card for completed inbox states and above pending reviewable candidates.
- [x] 1.4 Show provider/aggregate inbox label, relative completion time, no-action or review-ready outcome, and checked-message/likely-billing counts only when meaningful.
- [x] 1.5 Keep no-inbox and active-scan states free of a stale completed-check card and retain the current compact active-scan feedback.

## 2. Progressive disclosure and quality

- [x] 2.1 Add a low-emphasis Scan details disclosure from the Latest check card that opens the existing privacy-minimized details route.
- [x] 2.2 Add or update presentation-state tests for completed no-action, completed review-ready, no-count, no-inbox, active-scan, and multi-inbox latest-check cases.
- [x] 2.3 Verify Dynamic Type, VoiceOver labels, reduced-motion behavior, and privacy boundaries for the compact card and disclosure.
- [ ] 2.4 Build the simulator target and manually verify the healthy, active-scan, review-ready, no-inbox, no-count, and multi-inbox layouts.
- [x] 2.5 Update `todo.md` and Inbox Intelligence documentation with the latest-check proof-of-work behavior.
