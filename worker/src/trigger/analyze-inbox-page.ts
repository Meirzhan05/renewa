import { PostgresSaver } from "@langchain/langgraph-checkpoint-postgres";
import { task } from "@trigger.dev/sdk";
import { Pool } from "pg";
import { loadConfig } from "../config.ts";
import { PgJobStore } from "../db.ts";
import { claimManagedPageContext } from "../managed/edge-client.ts";
import { isAnalyzeInboxPagePayload, type AnalyzeInboxPagePayload } from "../managed/contracts.ts";
import { analyzeInboxPage, bridgeInboxProposals } from "../managed/page-analysis.ts";

export const analyzeInboxPageTask = task({
  id: "analyze-inbox-page",
  queue: { name: "inbox-agent-pages", concurrencyLimit: 20 },
  run: async (payload: AnalyzeInboxPagePayload, { ctx }) => {
    if (!isAnalyzeInboxPagePayload(payload)) throw new Error("Invalid managed Inbox page payload");
    const context = await claimManagedPageContext(payload, ctx.run.id);
    if (context.cancelled) return { cancelled: true };

    const config = loadConfig();
    const pool = new Pool({ connectionString: config.databaseUrl });
    const checkpointer = PostgresSaver.fromConnString(config.databaseUrl);
    try {
      await checkpointer.setup();
      const store = new PgJobStore(pool);
      const job = await store.claimPendingJob(payload.pageId, context.accessToken);
      if (!job) {
        await completeExecution(pool, context.executionId, "completed");
        return { alreadyCompleted: true };
      }
      try {
        const proposals = await withExecutionHeartbeat(pool, context.executionId, async () =>
          analyzeInboxPage(pool, checkpointer, job)
        );
        if (await store.isRunCancellationRequested(job.scanRunId)) {
          await store.failJob(job.id, "Scan cancelled by user.");
          await completeExecution(pool, context.executionId, "cancelled");
          return { cancelled: true };
        }
        await bridgeInboxProposals(pool, job, proposals);
        await store.finishAutonomousJob(job.id, proposals);
        await completeExecution(pool, context.executionId, "completed");
        return { proposals: proposals.length };
      } catch (error) {
        await store.failJob(job.id, errorMessage(error));
        await completeExecution(pool, context.executionId, "retryable", errorMessage(error));
        throw error;
      }
    } finally {
      await pool.end();
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
