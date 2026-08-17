export type InboxScanTerminalOutcome = "review_ready" | "no_new_discoveries" | "reconnect_required";

export function isInboxAuthorizationFailure(message: string): boolean {
  return /authorization|access token|reconnect your inbox|token.*expired/i.test(message);
}

export function deriveInboxScanTerminalOutcome(input: {
  pendingCandidateCount: number;
  errors: Array<string | null | undefined>;
}): InboxScanTerminalOutcome | null {
  if (input.pendingCandidateCount > 0) return "review_ready";
  const failures = input.errors.filter((error): error is string => Boolean(error));
  if (failures.some(isInboxAuthorizationFailure)) return "reconnect_required";
  if (failures.length > 0) return null;
  return "no_new_discoveries";
}

export function inboxScanOutcomeDeduplicationKey(batchID: string, outcome: InboxScanTerminalOutcome): string {
  return `inbox-scan:${batchID}:${outcome}`;
}

export function inboxScanLiveActivityDeduplicationKey(batchID: string, marker: string): string {
  return `inbox-live:${batchID}:${marker}`;
}
