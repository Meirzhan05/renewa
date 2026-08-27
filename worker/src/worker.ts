// The persistent backend service. A long-lived loop that claims and runs the next pending scan.
// Run state is durable in the PostgresSaver checkpointer, so a long scan survives restarts and
// resumes exactly where it paused — the capability the ephemeral edge function could not provide.

import { PostgresSaver } from "@langchain/langgraph-checkpoint-postgres";
import { Pool } from "pg";
import { loadConfig } from "./config.ts";
import { PgJobStore, type JobStore, type ScanJob } from "./db.ts";
import { createScanExecutor } from "./executor.ts";
import { buildGraph, type RouteOutcome } from "./graph/graph.ts";
import { isAutonomousModeEnabled, runTwoTierScan } from "./agent/pipeline.ts";
import { inMemoryReconcileReaders } from "./agent/tools.ts";
import type { ProposalCandidate } from "./agent/types.ts";
import {
  makeChatFn,
  resolveClassifierConfig,
  resolveReasonerConfig,
  type ChatFn,
} from "./llm/client.ts";

type CompiledGraph = ReturnType<typeof buildGraph>;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function collectResults(app: CompiledGraph, threadId: string): Promise<RouteOutcome[]> {
  const snapshot = await app.getState({ configurable: { thread_id: threadId } });
  const values = (snapshot.values ?? {}) as { results?: RouteOutcome[] };
  return values.results ?? [];
}

/** Drive one run to completion and persist its outcomes. */
async function driveRun(app: CompiledGraph, store: JobStore, job: ScanJob): Promise<void> {
  const config = { configurable: { thread_id: job.id } };
  await app.invoke({ rawMessages: job.rawMessages }, config);
  await store.finishJob(job.id, await collectResults(app, job.id));
}

// The narrow store surface the autonomous loop needs. PgJobStore satisfies it.
export type AutonomousStore = {
  claimNextPendingJob(): Promise<ScanJob | null>;
  finishAutonomousJob(jobId: string, proposals: ProposalCandidate[]): Promise<void>;
  failJob(jobId: string, error: string): Promise<void>;
};

/**
 * The autonomous two-tier loop (AGENT_MODE=autonomous). It claims a scan, runs the funnel, and
 * persists the proposals a person then confirms. `scanJob` is injected so the loop is unit-testable
 * without the model or Postgres.
 */
export async function runAutonomousLoop(deps: {
  store: AutonomousStore;
  scanJob: (job: ScanJob) => Promise<ProposalCandidate[]>;
  pollIntervalMs: number;
  isRunning: () => boolean;
}): Promise<void> {
  const { store, scanJob, pollIntervalMs, isRunning } = deps;
  while (isRunning()) {
    try {
      const job = await store.claimNextPendingJob();
      if (!job) {
        await sleep(pollIntervalMs);
        continue;
      }
      try {
        await store.finishAutonomousJob(job.id, await scanJob(job));
      } catch (error) {
        await store.failJob(job.id, String(error));
      }
    } catch (error) {
      console.error("[worker] autonomous loop error", error);
      await sleep(pollIntervalMs);
    }
  }
}

export async function runLoop(deps: {
  store: JobStore;
  buildForJob: (job: ScanJob) => CompiledGraph;
  pollIntervalMs: number;
  isRunning: () => boolean;
}): Promise<void> {
  const { store, buildForJob, pollIntervalMs, isRunning } = deps;
  while (isRunning()) {
    try {
      const job = await store.claimNextPendingJob();
      if (!job) {
        await sleep(pollIntervalMs);
        continue;
      }
      try {
        await driveRun(buildForJob(job), store, job);
      } catch (error) {
        await store.failJob(job.id, String(error));
      }
    } catch (error) {
      console.error("[worker] loop error", error);
      await sleep(pollIntervalMs);
    }
  }
}

async function main(): Promise<void> {
  const config = loadConfig();
  const pool = new Pool({ connectionString: config.databaseUrl });
  const checkpointer = PostgresSaver.fromConnString(config.databaseUrl);
  await checkpointer.setup();

  const store = new PgJobStore(pool);
  const chat: ChatFn = makeChatFn(resolveReasonerConfig());
  const classifierConfig = resolveClassifierConfig();
  const classifierChat: ChatFn = classifierConfig ? makeChatFn(classifierConfig) : chat;

  const buildForJob = (job: ScanJob): CompiledGraph =>
    buildGraph(
      { chat, classifierChat, executeTool: createScanExecutor(job.rawMessages) },
      checkpointer,
    );

  let running = true;
  const stop = () => {
    console.log("[worker] shutting down after current tick");
    running = false;
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);

  if (isAutonomousModeEnabled()) {
    console.log("[worker] started; AGENT_MODE=autonomous — two-tier funnel");
    // The app-side confirmation queue + learning tables are deferred, so reconcile is empty for now;
    // proposals land in scan_outcomes (kind='present').
    const scanJob = async (job: ScanJob): Promise<ProposalCandidate[]> => {
      const { proposals } = await runTwoTierScan(job.rawMessages, {
        chat,
        triageChat: classifierChat,
        reconcile: inMemoryReconcileReaders({}),
        checkpointer,
        threadId: job.id,
      });
      return proposals;
    };
    await runAutonomousLoop({ store, scanJob, pollIntervalMs: config.pollIntervalMs, isRunning: () => running });
  } else {
    console.log("[worker] started; polling for scan jobs");
    await runLoop({ store, buildForJob, pollIntervalMs: config.pollIntervalMs, isRunning: () => running });
  }
  await pool.end();
  console.log("[worker] stopped");
}

// Only run the service when executed directly (not when imported by tests).
if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((error) => {
    console.error("[worker] fatal", error);
    process.exit(1);
  });
}
