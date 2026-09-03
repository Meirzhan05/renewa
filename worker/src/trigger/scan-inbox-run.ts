import { task, wait } from "@trigger.dev/sdk";
import { isScanInboxRunPayload, type ScanInboxRunPayload } from "../managed/contracts.ts";
import { processManagedConnection } from "../managed/edge-client.ts";

type ManagedConnectionStep = {
  cancelled: boolean;
  hasNextPage: boolean;
  pageId: string | null;
  /** Milliseconds to hold off before asking for the next page. Zero on the ordinary path. */
  retryAfterMs?: number;
};

/**
 * Fetch continuation pages sequentially. Each fetched page is durably admitted by the Edge Function;
 * the scheduled dispatcher, not this parent task, later selects pages for analysis.
 *
 * A page that failed transiently comes back with `retryAfterMs` and no `pageId`: the Edge Function
 * has re-queued it behind a backoff. We must actually wait it out, because the claim honours
 * `available_at` — looping straight back would spin without claiming anything, and before that
 * filter existed it re-took the same page instantly and burned every attempt in milliseconds.
 */
export async function orchestrateManagedScan(
  payload: ScanInboxRunPayload,
  processConnection: (payload: ScanInboxRunPayload) => Promise<ManagedConnectionStep>,
  sleep: (ms: number) => Promise<void> = defaultSleep,
): Promise<{ cancelled: boolean; pagesProcessed: number }> {
  let pagesProcessed = 0;
  for (;;) {
    const result = await processConnection(payload);
    // Stop scheduling analyses the moment cancellation is observed during fetch.
    if (result.cancelled) return { cancelled: true, pagesProcessed: 0 };
    if (result.pageId) pagesProcessed += 1;
    if (!result.hasNextPage) break;
    if (result.retryAfterMs && result.retryAfterMs > 0) await sleep(result.retryAfterMs);
  }
  return { cancelled: false, pagesProcessed };
}

/** Trigger's durable wait, so a backoff survives the worker restarting mid-scan. */
async function defaultSleep(ms: number): Promise<void> {
  await wait.for({ seconds: Math.ceil(ms / 1000) });
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
