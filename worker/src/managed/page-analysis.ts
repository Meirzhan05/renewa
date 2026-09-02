import type { BaseCheckpointSaver } from "@langchain/langgraph";
import { Pool } from "pg";
import { bridgeProposalsToCandidates } from "../agent/candidate-bridge.ts";
import { runTwoTierScan } from "../agent/pipeline.ts";
import { createPgReconcileReaders } from "../agent/reconcile-db.ts";
import type { ProposalCandidate } from "../agent/types.ts";
import type { ScanJob } from "../db.ts";
import {
  makeChatFn,
  resolveClassifierConfig,
  resolveReasonerConfig,
  type ChatFn,
} from "../llm/client.ts";

export type PageAnalysis = {
  proposals: ProposalCandidate[];
  /** Tier-1 triage "look" set size for this page — the run's likely-billing total is the SUM of these. */
  lookCount: number;
};

/**
 * Runs the autonomous inbox funnel for one already-claimed page. This is deliberately independent
 * of the process-wide polling loop so a managed task can execute exactly one opaque page payload.
 */
export async function analyzeInboxPage(
  pool: Pool,
  checkpointer: BaseCheckpointSaver,
  job: ScanJob,
): Promise<PageAnalysis> {
  const chat: ChatFn = makeChatFn(resolveReasonerConfig());
  const classifierConfig = resolveClassifierConfig();
  const triageChat: ChatFn = classifierConfig ? makeChatFn(classifierConfig) : chat;
  const { proposals, triage } = await runTwoTierScan(job.rawMessages, {
    chat,
    triageChat,
    reconcile: createPgReconcileReaders(pool, job.userId),
    checkpointer,
    threadId: job.id,
    provider: job.provider,
    accessToken: job.accessToken,
  });
  return { proposals, lookCount: triage.lookCount };
}

/**
 * Persist this page's Tier-1 triage "look" count on its worker-queue row so the run's app-visible
 * likely-billing figure can be derived as SUM(triage_look_count). Idempotent (a plain set), so a
 * re-run of the page overwrites its own row rather than inflating the total.
 */
export async function recordPageTriageCount(
  pool: Pool,
  jobId: string,
  lookCount: number,
): Promise<void> {
  await pool.query("update scan_jobs set triage_look_count = $2 where id = $1", [jobId, lookCount]);
}

export async function bridgeInboxProposals(
  pool: Pool,
  job: ScanJob,
  proposals: ProposalCandidate[],
): Promise<void> {
  if (!job.scanRunId) return;
  await bridgeProposalsToCandidates(pool, {
    userId: job.userId,
    scanRunId: job.scanRunId,
    provider: job.provider,
    messagesScanned: job.rawMessages.length,
    proposals,
    // The page's messages are already in hand, so merchant identity resolves from the evidence
    // sender without an extra fetch.
    messageSenders: new Map(job.rawMessages.map((m) => [m.id, m.sender])),
  });
}
