// The persistent backend service. A long-lived loop that (1) resumes any clarifications the user
// has answered since the last tick, then (2) claims and runs the next pending scan. Run state is
// durable in the PostgresSaver checkpointer, so an interrupted scan survives restarts and resumes
// exactly where it paused — the capability the ephemeral edge function could not provide.

import { Command } from "@langchain/langgraph";
import { PostgresSaver } from "@langchain/langgraph-checkpoint-postgres";
import { Pool } from "pg";
import { loadConfig } from "./config.ts";
import { PgJobStore, type JobStore, type OpenClarification, type ScanJob } from "./db.ts";
import { createScanExecutor } from "./executor.ts";
import { buildGraph, type ClarifyPayload, type RouteOutcome } from "./graph/graph.ts";
import {
  makeChatFn,
  resolveClassifierConfig,
  resolveReasonerConfig,
  type ChatFn,
} from "./llm/client.ts";

type CompiledGraph = ReturnType<typeof buildGraph>;

type PendingInterrupt = { interruptId: string; payload: ClarifyPayload };

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Read whatever interrupts a run is currently paused on. Empty when the run finished. */
async function pendingInterrupts(app: CompiledGraph, threadId: string): Promise<PendingInterrupt[]> {
  const snapshot = await app.getState({ configurable: { thread_id: threadId } });
  const tasks = (snapshot.tasks ?? []) as ReadonlyArray<{
    interrupts?: ReadonlyArray<{ value?: unknown; id?: string }>;
  }>;
  const out: PendingInterrupt[] = [];
  for (const task of tasks) {
    for (const [index, interrupt] of (task.interrupts ?? []).entries()) {
      out.push({
        interruptId: String(interrupt.id ?? `${threadId}:${out.length + index}`),
        payload: interrupt.value as ClarifyPayload,
      });
    }
  }
  return out;
}

async function collectResults(app: CompiledGraph, threadId: string): Promise<RouteOutcome[]> {
  const snapshot = await app.getState({ configurable: { thread_id: threadId } });
  const values = (snapshot.values ?? {}) as { results?: RouteOutcome[] };
  return values.results ?? [];
}

/**
 * Drive one run to its next stopping point — either a clarification interrupt (persist + await the
 * user) or completion (persist outcomes). `resume` is set when continuing an answered clarification.
 */
async function driveRun(
  app: CompiledGraph,
  store: JobStore,
  job: ScanJob,
  resume?: string,
): Promise<void> {
  const config = { configurable: { thread_id: job.id } };
  const input = resume !== undefined ? new Command({ resume }) : { rawMessages: job.rawMessages };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  await app.invoke(input as any, config);

  const interrupts = await pendingInterrupts(app, job.id);
  if (interrupts.length > 0) {
    await store.markAwaitingUser(job.id, interrupts);
    return;
  }
  await store.finishJob(job.id, await collectResults(app, job.id));
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
      // 1. Resume runs the user has answered since the last tick.
      const answered: OpenClarification[] = await store.claimAnsweredClarifications();
      for (const clar of answered) {
        const job = await store.getJob(clar.jobId);
        if (!job) continue;
        try {
          await driveRun(buildForJob(job), store, job, clar.answer);
          await store.resolveClarification(clar);
        } catch (error) {
          await store.failJob(job.id, String(error));
        }
      }

      // 2. Start the next pending scan.
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

  console.log("[worker] started; polling for scan jobs");
  await runLoop({ store, buildForJob, pollIntervalMs: config.pollIntervalMs, isRunning: () => running });
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
