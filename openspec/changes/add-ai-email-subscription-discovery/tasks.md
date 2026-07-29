## 1. Data foundation

- [x] 1.1 Add forward-only schema for sync cursors, scan jobs/progress, candidate review, canonical merchant identity, RLS, grants, indexes, and cascades.
- [x] 1.2 Add pure discovery helpers for candidate filtering, content minimization, structured-event validation, merchant normalization, and proposal classification.
- [x] 1.3 Add backend tests for validation, prompt-injection content, merchant matching, review classification, and idempotent transitions.

## 2. Asynchronous discovery service

- [x] 2.1 Refactor `email-scan` into authenticated start/status coordination with one durable job per connected inbox and resumable background processing.
- [x] 2.2 Add bounded Gmail bootstrap/history pagination and Microsoft delta synchronization with cursor advancement only after success.
- [x] 2.3 Add metadata-first selection, bounded full-content retrieval, per-message AI extraction, runtime schema rejection, and non-sensitive telemetry.
- [x] 2.4 Add deterministic reconciliation and persist pending candidates without automatically mutating subscriptions.
- [x] 2.5 Add authenticated confirm/edit/ignore operations with ownership checks and idempotent subscription application.
- [x] 2.6 Add connection summaries, best-effort provider revocation, disconnect, and scan-history cleanup operations.

## 3. iOS experience

- [x] 3.1 Add client models and API operations for scan start/status, progress, candidates, decisions, and connection controls.
- [x] 3.2 Update `AppStore` with recoverable scan state, polling, candidate decisions, subscription refresh, and disconnect behavior.
- [x] 3.3 Redesign Inbox Intelligence to show connections, asynchronous progress, partial failures, and reviewable candidate cards.
- [x] 3.4 Add candidate editing and explicit confirmation/ignore controls with accessible pending and empty states.

## 4. Quality and delivery

- [x] 4.1 Add XCTest coverage for scan aggregation, progress copy, candidate confirmation eligibility, and review-state presentation.
- [x] 4.2 Align README, Function environment documentation, deployment commands, privacy boundaries, and architecture map with the implemented AI provider and pipeline.
- [x] 4.3 Update `todo.md`, run focused lint, backend tests, XCTest, simulator/device builds, migration checks, and OpenSpec validation.
