export const MANAGED_INBOX_TASK_VERSION = 2 as const;

export type ScanInboxRunPayload = {
  version: typeof MANAGED_INBOX_TASK_VERSION;
  scanRunId: string;
  connectionId: string;
};

export type AnalyzeInboxPagePayload = {
  version: typeof MANAGED_INBOX_TASK_VERSION;
  scanRunId: string;
  pageId: string;
  executionId: string;
  dispatchToken: string;
};

export function scanRunIdempotencyKey(scanRunId: string): string {
  return `inbox-scan-run:v${MANAGED_INBOX_TASK_VERSION}:${scanRunId}`;
}

export function pageAnalysisIdempotencyKey(executionId: string, dispatchToken: string): string {
  return `inbox-page-analysis:v${MANAGED_INBOX_TASK_VERSION}:${executionId}:${dispatchToken}`;
}

export function isScanInboxRunPayload(value: unknown): value is ScanInboxRunPayload {
  if (!value || typeof value !== "object") return false;
  const payload = value as Record<string, unknown>;
  return Object.keys(payload).every((key) => ["version", "scanRunId", "connectionId"].includes(key)) &&
    payload.version === MANAGED_INBOX_TASK_VERSION &&
    typeof payload.scanRunId === "string" && payload.scanRunId.length > 0 &&
    typeof payload.connectionId === "string" && payload.connectionId.length > 0;
}

export function isAnalyzeInboxPagePayload(value: unknown): value is AnalyzeInboxPagePayload {
  if (!value || typeof value !== "object") return false;
  const payload = value as Record<string, unknown>;
  return Object.keys(payload).every((key) => ["version", "scanRunId", "pageId", "executionId", "dispatchToken"].includes(key)) &&
    payload.version === MANAGED_INBOX_TASK_VERSION &&
    typeof payload.scanRunId === "string" && payload.scanRunId.length > 0 &&
    typeof payload.pageId === "string" && payload.pageId.length > 0 &&
    typeof payload.executionId === "string" && payload.executionId.length > 0 &&
    typeof payload.dispatchToken === "string" && payload.dispatchToken.length > 0;
}
