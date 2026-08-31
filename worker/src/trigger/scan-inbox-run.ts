import { task } from "@trigger.dev/sdk";
import { isScanInboxRunPayload, type ScanInboxRunPayload } from "../managed/contracts.ts";
import { processManagedConnection } from "../managed/edge-client.ts";

type ManagedConnectionStep = {
  cancelled: boolean;
  hasNextPage: boolean;
  pageId: string | null;
};

/**
 * Fetch continuation pages sequentially. Each fetched page is durably admitted by the Edge Function;
 * the scheduled dispatcher, not this parent task, later selects pages for analysis.
 */
export async function orchestrateManagedScan(
  payload: ScanInboxRunPayload,
  processConnection: (payload: ScanInboxRunPayload) => Promise<ManagedConnectionStep>,
): Promise<{ cancelled: boolean; pagesProcessed: number }> {
  let pagesProcessed = 0;
  for (;;) {
    const result = await processConnection(payload);
    // Stop scheduling analyses the moment cancellation is observed during fetch.
    if (result.cancelled) return { cancelled: true, pagesProcessed: 0 };
    if (result.pageId) pagesProcessed += 1;
    if (!result.hasNextPage) break;
  }
  return { cancelled: false, pagesProcessed };
}

/** One durable orchestrator per connection/run. It fetches pages; the dispatcher owns analysis. */
export const scanInboxRunTask = task({
  id: "scan-inbox-run",
  queue: { name: "inbox-agent-runs", concurrencyLimit: 4 },
  run: async (payload: ScanInboxRunPayload) => {
    if (!isScanInboxRunPayload(payload)) throw new Error("Invalid managed Inbox run payload");
    return orchestrateManagedScan(payload, processManagedConnection);
  },
});
