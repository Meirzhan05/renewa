import { PostgresSaver } from "@langchain/langgraph-checkpoint-postgres";
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

/**
 * Runs the autonomous inbox funnel for one already-claimed page. This is deliberately independent
 * of the process-wide polling loop so a managed task can execute exactly one opaque page payload.
 */
export async function analyzeInboxPage(
  pool: Pool,
  checkpointer: PostgresSaver,
  job: ScanJob,
): Promise<ProposalCandidate[]> {
  const chat: ChatFn = makeChatFn(resolveReasonerConfig());
  const classifierConfig = resolveClassifierConfig();
  const triageChat: ChatFn = classifierConfig ? makeChatFn(classifierConfig) : chat;
  const { proposals } = await runTwoTierScan(job.rawMessages, {
    chat,
    triageChat,
    reconcile: createPgReconcileReaders(pool, job.userId),
    checkpointer,
    threadId: job.id,
    provider: job.provider,
    accessToken: job.accessToken,
  });
  return proposals;
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
  });
}
