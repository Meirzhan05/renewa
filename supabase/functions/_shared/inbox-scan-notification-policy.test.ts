import {
  deriveInboxScanTerminalOutcome,
  inboxScanLiveActivityDeduplicationKey,
  inboxScanOutcomeDeduplicationKey,
} from "./inbox-scan-notification-policy.ts";

Deno.test("notification policy prefers a review-ready outcome and keeps batch deduplication stable", () => {
  const outcome = deriveInboxScanTerminalOutcome({
    pendingCandidateCount: 2,
    errors: ["OAuth access token expired"],
  });
  if (outcome !== "review_ready") throw new Error(`Expected review_ready, got ${outcome}`);
  if (inboxScanOutcomeDeduplicationKey("batch-1", outcome) !== "inbox-scan:batch-1:review_ready") {
    throw new Error("Outcome deduplication key changed unexpectedly");
  }
});

Deno.test("notification policy classifies authorization-only failures as reconnect required", () => {
  const outcome = deriveInboxScanTerminalOutcome({
    pendingCandidateCount: 0,
    errors: ["The access token expired. Reconnect your inbox."],
  });
  if (outcome !== "reconnect_required") throw new Error(`Expected reconnect_required, got ${outcome}`);
});

Deno.test("notification policy sends no outcome for unrelated failures and no-discovery outcome for a clean batch", () => {
  const failed = deriveInboxScanTerminalOutcome({ pendingCandidateCount: 0, errors: ["Provider timed out"] });
  const clean = deriveInboxScanTerminalOutcome({ pendingCandidateCount: 0, errors: [] });
  if (failed !== null) throw new Error(`Expected no outcome, got ${failed}`);
  if (clean !== "no_new_discoveries") throw new Error(`Expected no_new_discoveries, got ${clean}`);
  if (inboxScanLiveActivityDeduplicationKey("batch-1", "extracting:42") !== "inbox-live:batch-1:extracting:42") {
    throw new Error("Live Activity deduplication key changed unexpectedly");
  }
});
