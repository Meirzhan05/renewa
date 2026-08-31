import { task } from "@trigger.dev/sdk";
import type { Pool } from "pg";
import { PgJobStore } from "../db.ts";
import { withManagedDatabase } from "../managed/database.ts";
import { claimManagedPageContext } from "../managed/edge-client.ts";
import { isAnalyzeInboxPagePayload, type AnalyzeInboxPagePayload } from "../managed/contracts.ts";
import { loadManagedRuntimeConfig } from "../managed/config.ts";
import { analyzeInboxPage, bridgeInboxProposals, recordPageTriageCount } from "../managed/page-analysis.ts";

export const analyzeInboxPageTask = task({
  id: "analyze-inbox-page",
  // This is one shared queue; the durable dispatcher decides fair per-user admission before work is
  // submitted. A concurrency key would create independent queues and bypass the global budget.
  queue: { name: "inbox-agent-pages", concurrencyLimit: loadManagedRuntimeConfig().globalConcurrency },
  retry: { maxAttempts: 1 },
  // A page is ~100 messages; 10 min is a generous ceiling. Combined with the per-model-call timeout,
  // a hung page is killed and retried within minutes instead of stalling for the default hour.
  maxDuration: 600,
  run: async (payload: AnalyzeInboxPagePayload, { ctx }) => {
    if (!isAnalyzeInboxPagePayload(payload)) throw new Error("Invalid managed Inbox page payload");
    try {
      const context = await claimManagedPageContext(payload, ctx.run.id);
      if (context.cancelled) return { cancelled: true };
      return await withManagedDatabase(async ({ pool, checkpointer }) => {
        const store = new PgJobStore(pool);
        const job = await store.claimPendingJob(payload.pageId, context.accessToken);
        if (!job) {
          await completeExecution(pool, context.executionId, "completed");
          return { alreadyCompleted: true };
        }
        try {
          const analysis = await withExecutionHeartbeat(pool, context.executionId, async () =>
            analyzeInboxPage(pool, checkpointer, job)
          );
          if (await store.isRunCancellationRequested(job.scanRunId)) {
            await store.failJob(job.id, "Scan cancelled by user.");
            await completeExecution(pool, context.executionId, "cancelled");
            return { cancelled: true };
          }
          await recordPageTriageCount(pool, job.id, analysis.lookCount);
          await bridgeInboxProposals(pool, job, analysis.proposals);
          await store.finishAutonomousJob(job.id, analysis.proposals);
          await completeExecution(pool, context.executionId, "completed");
          return { proposals: analysis.proposals.length };
        } catch (error) {
          const message = errorMessage(error);
          await store.releaseJobForRetry(job.id, message);
          await completeExecution(pool, context.executionId, "retryable", message);
          return { retryable: true, error: message };
        }
      });
    } catch (error) {
      // Do not throw: the ledger/dispatcher is the single retry authority. If the task reached a
      // claimed page, return it to pending work; otherwise the reservation lease will be reaped.
      return { retryable: true, error: errorMessage(error) };
    }
  },
});

async function completeExecution(pool: Pool, executionID: string, state: "completed" | "retryable" | "cancelled", error?: string) {
  await pool.query(
    "select public.complete_inbox_agent_execution($1, $2::public.inbox_agent_execution_state, $3)",
    [executionID, state, error?.slice(0, 500) ?? null],
  );
}

async function withExecutionHeartbeat<T>(pool: Pool, executionID: string, work: () => Promise<T>): Promise<T> {
  const interval = setInterval(() => {
    void pool.query("select public.heartbeat_inbox_agent_execution($1)", [executionID]);
  }, 45_000);
  try {
    return await work();
  } finally {
    clearInterval(interval);
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
