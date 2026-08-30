import { task } from "@trigger.dev/sdk";
import {
  isScanInboxRunPayload,
  MANAGED_INBOX_TASK_VERSION,
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

type ManagedPageWaiter = (payload: {
  version: typeof MANAGED_INBOX_TASK_VERSION;
  scanRunId: string;
  pageId: string;
}) => Promise<{ cancelled: boolean }>;

/**
 * Fetch exactly one mailbox page, then wait for its durable analysis before advancing. Waiting at
 * a child-task checkpoint releases the parent queue slot, so other users can start their scans.
 */
export async function orchestrateManagedScan(
  payload: ScanInboxRunPayload,
  processConnection: (payload: ScanInboxRunPayload) => Promise<ManagedConnectionStep>,
  waitForPage: ManagedPageWaiter,
): Promise<{ cancelled: boolean; pagesProcessed: number }> {
  let pagesProcessed = 0;
  for (;;) {
    const result = await processConnection(payload);
    if (result.cancelled) return { cancelled: true, pagesProcessed };
    if (result.pageId) {
      const page = await waitForPage({
        version: MANAGED_INBOX_TASK_VERSION,
        scanRunId: payload.scanRunId,
        pageId: result.pageId,
      });
      if (page.cancelled) return { cancelled: true, pagesProcessed };
      pagesProcessed += 1;
    }
    if (!result.hasNextPage) return { cancelled: false, pagesProcessed };
  }
}

/** One durable orchestrator per connection/run. It fetches pages sequentially and fans page analysis out. */
export const scanInboxRunTask = task({
  id: "scan-inbox-run",
  queue: { name: "inbox-agent-runs", concurrencyLimit: 20 },
  run: async (payload: ScanInboxRunPayload) => {
    if (!isScanInboxRunPayload(payload)) throw new Error("Invalid managed Inbox run payload");
    return orchestrateManagedScan(
      payload,
      processManagedConnection,
      async (page) => {
        const pageResult = await analyzeInboxPageTask.triggerAndWait(
          page,
          { idempotencyKey: pageAnalysisIdempotencyKey(page.scanRunId, page.pageId) },
        );
        if (!pageResult.ok) throw new Error("Managed page analysis task failed");
        return { cancelled: pageResult.output.cancelled === true };
      },
    );
  },
});
