// The persistent backend service. A long-lived loop that claims and runs the next pending scan.
// Run state is durable in the PostgresSaver checkpointer, so a long scan survives restarts and
// resumes exactly where it paused — the capability the ephemeral edge function could not provide.

import { pathToFileURL } from "node:url";
import { PostgresSaver } from "@langchain/langgraph-checkpoint-postgres";
import { Pool } from "pg";
import { loadConfig } from "./config.ts";
import { PgJobStore, type JobStore, type ScanJob } from "./db.ts";
import { createScanExecutor } from "./executor.ts";
import { buildGraph, type RouteOutcome } from "./graph/graph.ts";
import { isAutonomousModeEnabled, runTwoTierScan } from "./agent/pipeline.ts";
import { createPgReconcileReaders } from "./agent/reconcile-db.ts";
import { bridgeProposalsToCandidates } from "./agent/candidate-bridge.ts";
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
    // Reconcile against the user's real tracked subscriptions, learned priors, suppressions, and
    // aliases (per job, since it is per-user) so the agent never re-proposes a duplicate or a
    // suppressed merchant. Proposals land in scan_outcomes (kind='present'); bridging them into the
    // app's subscription_candidates review queue is the next integration step.
    const scanJob = async (job: ScanJob): Promise<ProposalCandidate[]> => {
      console.log(
        `[worker] claim ${job.id} · ${job.provider} · ${job.rawMessages.length} msgs · run=${job.scanRunId ?? "none"}`,
      );
      const { proposals, triage } = await runTwoTierScan(job.rawMessages, {
        chat,
        triageChat: classifierChat,
        reconcile: createPgReconcileReaders(pool, job.userId),
        checkpointer,
        threadId: job.id,
        // Let the agent read full message bodies on demand (Gmail) with the connection's token.
        provider: job.provider,
        accessToken: job.accessToken,
      });
      // Per-job visibility: triage narrowing, whether the model degraded, and what got proposed.
      console.log(
        `[worker] ${job.id}: triage ${triage.lookCount} look / ${triage.skipCount} skip` +
          `${triage.degraded ? " (DEGRADED — triage model calls failed)" : ""} -> ` +
          `${proposals.length} proposal(s)` +
          `${proposals.length ? ": " + proposals.map((p) => p.merchant_name).join(", ") : ""}`,
      );
      // Bridge proposals into the app's review queue and complete the app-side run, so the iOS app
      // sees candidates through its existing endpoint. Standalone jobs (no app run) skip the bridge.
      if (job.scanRunId) {
        const written = await bridgeProposalsToCandidates(pool, {
          userId: job.userId,
          scanRunId: job.scanRunId,
          provider: job.provider,
          messagesScanned: job.rawMessages.length,
          proposals,
        });
        console.log(`[worker] ${job.id}: bridged ${written} candidate(s) into the review queue`);
      }
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

// Only run the service when executed directly (not when imported by tests). `pathToFileURL`
// percent-encodes the path (e.g. spaces → %20) to match `import.meta.url`; a raw `file://${argv}`
// template silently fails to match whenever the path contains a space, so the service never starts.
if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  main().catch((error) => {
    console.error("[worker] fatal", error);
    process.exit(1);
  });
}
