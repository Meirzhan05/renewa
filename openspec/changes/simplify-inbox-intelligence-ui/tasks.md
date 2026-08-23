## 1. Focused assistant landing state

- [x] 1.1 Audit the current `EmailScanView` sections and state mapping; retain the existing durable scan/candidate data while identifying the dashboard-only UI that moves out of the default flow.
- [x] 1.2 Implement a compact Inbox Intelligence status surface for no inbox, healthy monitoring, active scan, review-ready, and needs-attention states.
- [x] 1.3 Replace the default scan-health metric hero, live activity timeline, and permanent learning/history content with concise state-specific copy and only relevant primary actions.
- [x] 1.4 Keep pending subscription candidate review cards as the landing page’s primary content and provide a calm no-action state when none are pending.
- [x] 1.5 Preserve compact, durable active-scan stage/count feedback and safe background-continuation copy without an invented percentage or persistent animation.

## 2. Progressive disclosure routes

- [x] 2.1 Add Inbox settings access from the Inbox Intelligence navigation UI using the app’s existing sheet or navigation conventions.
- [x] 2.2 Move connected inbox management, reconnect/disconnect, alert preference, Check now, paused suggestions, scan history/clear-history, and privacy guidance into Inbox settings without changing their actions or confirmations.
- [x] 2.3 Add a secondary Scan details route for privacy-minimized non-actionable outcomes and diagnostics, preserving existing evidence-detail privacy restrictions.
- [x] 2.4 Route no-inbox and recoverable failure states directly to the relevant connection or recovery action, and ensure ordinary healthy monitoring does not foreground manual scanning.

## 3. State handling, accessibility, and verification

- [x] 3.1 Update presentation-state tests for assistant-home states, including no inbox, healthy monitoring, scanning, review-ready, reconnect-required, and a completed scan with no pending candidate.
- [x] 3.2 Verify VoiceOver labels, Dynamic Type layout, reduced-motion behavior, and no raw mail/model content across the landing, settings, and detail routes.
- [ ] 3.3 Build the simulator target and manually verify normal monitoring, active scan/tab switch, pending review, no-action completion, settings actions, scan details, and provider recovery.
- [x] 3.4 Update `todo.md` and Inbox Intelligence documentation to describe the assistant-first hierarchy and where secondary controls now live.
