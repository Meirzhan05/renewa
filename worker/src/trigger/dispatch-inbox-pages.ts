import { schedules } from "@trigger.dev/sdk";
import { Pool } from "pg";
import { loadManagedDatabaseConfig, loadManagedRuntimeConfig } from "../managed/config.ts";
import {
  MANAGED_INBOX_TASK_VERSION,
  pageAnalysisIdempotencyKey,
  type AnalyzeInboxPagePayload,
} from "../managed/contracts.ts";
import { analyzeInboxPageTask } from "./analyze-inbox-page.ts";

export type ReservedInboxPage = {
  executionId: string;
  scanRunId: string;
  pageId: string;
  dispatchToken: string;
};

type PageTrigger = (payload: AnalyzeInboxPagePayload, options: { idempotencyKey: string }) => Promise<{ id: string }>;

export async function reserveInboxPages(pool: Pool, limit?: number): Promise<ReservedInboxPage[]> {
  const budget = loadManagedRuntimeConfig();
  const { rows } = await pool.query(
    `select * from public.reserve_inbox_agent_executions($1, $2, $3, $4, $5, $6)`,
    [limit ?? budget.globalConcurrency, budget.globalConcurrency, budget.googleConcurrency,
      budget.microsoftConcurrency, budget.perUserConcurrency, 120],
  );
  return rows.map((row) => ({
    executionId: String(row.execution_id), scanRunId: String(row.scan_run_id),
    pageId: String(row.scan_job_id), dispatchToken: String(row.dispatch_token),
  }));
}

export async function dispatchReservedInboxPages(
  pool: Pool,
  pages: ReservedInboxPage[],
  trigger: PageTrigger,
): Promise<{ dispatched: number; released: number }> {
  let dispatched = 0;
  let released = 0;
  for (const page of pages) {
    const payload: AnalyzeInboxPagePayload = {
      version: MANAGED_INBOX_TASK_VERSION,
      scanRunId: page.scanRunId,
      pageId: page.pageId,
      executionId: page.executionId,
      dispatchToken: page.dispatchToken,
    };
    try {
      const run = await trigger(payload, {
        idempotencyKey: pageAnalysisIdempotencyKey(page.executionId, page.dispatchToken),
      });
      const attached = await pool.query(
        "select public.attach_inbox_agent_runtime($1, $2, $3) as attached",
        [page.executionId, page.dispatchToken, run.id],
      );
      if (attached.rows[0]?.attached !== true) throw new Error("Dispatch reservation was no longer valid");
      dispatched += 1;
    } catch (error) {
      await pool.query("select public.release_inbox_agent_dispatch($1, $2, $3)", [
        page.executionId, page.dispatchToken, error instanceof Error ? error.message.slice(0, 500) : String(error).slice(0, 500),
      ]);
      released += 1;
    }
  }
  return { dispatched, released };
}

/** The durable page dispatcher. Development schedules run only while `trigger:dev` is connected. */
export const dispatchInboxPagesTask = schedules.task({
  id: "dispatch-inbox-pages",
  cron: "* * * * *",
  queue: { name: "inbox-agent-dispatch", concurrencyLimit: 1 },
  retry: { maxAttempts: 1 },
  run: async () => {
    const database = loadManagedDatabaseConfig();
    // Page graphs now use an in-process MemorySaver, so there are no Postgres checkpoint tables to
    // bootstrap here anymore.
    const pool = new Pool({ connectionString: database.databaseUrl, max: database.poolMax });
    try {
      const pages = await reserveInboxPages(pool);
      return await dispatchReservedInboxPages(pool, pages, (payload, options) =>
        analyzeInboxPageTask.trigger(payload, options),
      );
    } finally {
      await pool.end();
    }
  },
});
