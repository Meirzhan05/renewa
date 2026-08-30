import { task } from "@trigger.dev/sdk";
import { isScanInboxRunPayload, type ScanInboxRunPayload } from "../managed/contracts.ts";
import { processManagedConnection } from "../managed/edge-client.ts";

/** One durable orchestrator per connection/run. It fetches pages sequentially and fans page analysis out. */
export const scanInboxRunTask = task({
  id: "scan-inbox-run",
  queue: { name: "inbox-agent-runs", concurrencyLimit: 20 },
  run: async (payload: ScanInboxRunPayload) => {
    if (!isScanInboxRunPayload(payload)) throw new Error("Invalid managed Inbox run payload");
    let pagesProcessed = 0;
    for (;;) {
      const result = await processManagedConnection(payload);
      if (result.cancelled || !result.hasNextPage) {
        return { cancelled: result.cancelled, pagesProcessed };
      }
      pagesProcessed += 1;
    }
  },
});
