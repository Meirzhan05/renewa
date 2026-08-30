export const MANAGED_INBOX_TASK_VERSION = 1 as const;

export type ScanInboxRunPayload = {
  version: typeof MANAGED_INBOX_TASK_VERSION;
  scanRunId: string;
  connectionId: string;
};

export type AnalyzeInboxPagePayload = {
  version: typeof MANAGED_INBOX_TASK_VERSION;
  scanRunId: string;
  pageId: string;
};

export function scanRunIdempotencyKey(scanRunId: string): string {
  return `inbox-scan-run:v${MANAGED_INBOX_TASK_VERSION}:${scanRunId}`;
}

export function pageAnalysisIdempotencyKey(scanRunId: string, pageId: string): string {
  return `inbox-page-analysis:v${MANAGED_INBOX_TASK_VERSION}:${scanRunId}:${pageId}`;
}

/**
 * Concurrency key for page analyses of one run. Trigger.dev copies the queue per unique key, so every
 * page of a run shares one copy bounded by the per-user analysis budget. A run belongs to a single
 * user, so a per-run key is the per-user bound.
 */
export function pageAnalysisConcurrencyKey(scanRunId: string): string {
  return `inbox-page:${scanRunId}`;
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
  return Object.keys(payload).every((key) => ["version", "scanRunId", "pageId"].includes(key)) &&
    payload.version === MANAGED_INBOX_TASK_VERSION &&
    typeof payload.scanRunId === "string" && payload.scanRunId.length > 0 &&
    typeof payload.pageId === "string" && payload.pageId.length > 0;
}
