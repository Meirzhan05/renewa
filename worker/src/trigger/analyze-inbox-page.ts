import { PostgresSaver } from "@langchain/langgraph-checkpoint-postgres";
import { task } from "@trigger.dev/sdk";
import { Pool } from "pg";
import { loadConfig } from "../config.ts";
import { PgJobStore } from "../db.ts";
import { claimManagedPageContext } from "../managed/edge-client.ts";
import { isAnalyzeInboxPagePayload, type AnalyzeInboxPagePayload } from "../managed/contracts.ts";
import { perUserAnalysisConcurrency } from "../managed/config.ts";
import { analyzeInboxPage, bridgeInboxProposals, recordPageTriageCount } from "../managed/page-analysis.ts";

export const analyzeInboxPageTask = task({
  id: "analyze-inbox-page",
  // With a per-run concurrency key (see scan-inbox-run), this limit applies per run, so it is the
  // per-user analysis budget; global load stays bounded by the environment/provider ceilings.
  queue: { name: "inbox-agent-pages", concurrencyLimit: perUserAnalysisConcurrency() },
  // A page is ~100 messages; 10 min is a generous ceiling. Combined with the per-model-call timeout,
  // a hung page is killed and retried within minutes instead of stalling for the default hour.
  maxDuration: 600,
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
