import { task } from "@trigger.dev/sdk";
import {
  type AnalyzeInboxPagePayload,
  isScanInboxRunPayload,
  MANAGED_INBOX_TASK_VERSION,
  pageAnalysisConcurrencyKey,
  pageAnalysisIdempotencyKey,
  type ScanInboxRunPayload,
} from "../managed/contracts.ts";
import { processManagedConnection } from "../managed/edge-client.ts";
import { analyzeInboxPageTask } from "./analyze-inbox-page.ts";

type ManagedConnectionStep = {
  cancelled: boolean;
  hasNextPage: boolean;
  pageId: string | null;
};

/** Analyze a run's already-fetched pages together; resolves once every page is terminal. */
type ManagedPageBatchAnalyzer = (
  pages: AnalyzeInboxPagePayload[],
) => Promise<{ cancelled: boolean }>;

/**
 * Fetch a connection's mailbox pages sequentially (the provider continuation cursor is ordered), then
 * analyze them concurrently. Fanning analysis out — rather than awaiting each page before fetching the
 * next — is the throughput win; a per-run concurrency key bounds how many analyses run at once so a
 * single scan stays within its per-user budget.
 */
export async function orchestrateManagedScan(
  payload: ScanInboxRunPayload,
  processConnection: (payload: ScanInboxRunPayload) => Promise<ManagedConnectionStep>,
  analyzePages: ManagedPageBatchAnalyzer,
): Promise<{ cancelled: boolean; pagesProcessed: number }> {
  const pages: AnalyzeInboxPagePayload[] = [];
  for (;;) {
    const result = await processConnection(payload);
    // Stop scheduling analyses the moment cancellation is observed during fetch.
    if (result.cancelled) return { cancelled: true, pagesProcessed: 0 };
    if (result.pageId) {
      pages.push({
        version: MANAGED_INBOX_TASK_VERSION,
        scanRunId: payload.scanRunId,
        pageId: result.pageId,
      });
    }
    if (!result.hasNextPage) break;
  }
  if (pages.length === 0) return { cancelled: false, pagesProcessed: 0 };
  const outcome = await analyzePages(pages);
  return { cancelled: outcome.cancelled, pagesProcessed: pages.length };
}

/** Batch items for the page-analysis fan-out: idempotent per page, concurrency-bounded per run. */
export function pageAnalysisBatchItems(pages: AnalyzeInboxPagePayload[]) {
  return pages.map((page) => ({
    payload: page,
    options: {
      idempotencyKey: pageAnalysisIdempotencyKey(page.scanRunId, page.pageId),
      concurrencyKey: pageAnalysisConcurrencyKey(page.scanRunId),
    },
  }));
}

/** One durable orchestrator per connection/run. It fetches pages sequentially and fans analysis out. */
export const scanInboxRunTask = task({
  id: "scan-inbox-run",
  queue: { name: "inbox-agent-runs", concurrencyLimit: 20 },
  run: async (payload: ScanInboxRunPayload) => {
    if (!isScanInboxRunPayload(payload)) throw new Error("Invalid managed Inbox run payload");
    return orchestrateManagedScan(payload, processManagedConnection, async (pages) => {
      // batchTriggerAndWait checkpoints this run (releasing its queue slot) while the pages analyze in
      // parallel, up to the per-run concurrency key's limit.
      const batch = await analyzeInboxPageTask.batchTriggerAndWait(pageAnalysisBatchItems(pages));
      let cancelled = false;
      for (const pageRun of batch.runs) {
        if (!pageRun.ok) throw new Error("Managed page analysis task failed");
        if ((pageRun.output as { cancelled?: boolean } | undefined)?.cancelled === true) {
          cancelled = true;
        }
      }
      return { cancelled };
    });
  },
});
