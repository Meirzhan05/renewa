// The two-tier funnel, composed and selectable behind a flag. Tier-1 `triageInbox` decides which
// mail the expensive agent sees; Tier-2 `buildAgentGraph` does all judgment and proposes. This
// module is the engine-level composition and the flag gate (`isAutonomousModeEnabled`); wiring it
// into the live worker loop (swapping the old per-merchant graph) is the final integration step.

import { MemorySaver } from "@langchain/langgraph";
import type { BaseCheckpointSaver } from "@langchain/langgraph";
import { senderDomain, type MailMetadata } from "../domain/email.ts";
import type { ChatFn } from "../llm/client.ts";
import { buildAgentGraph, type AgentReadExecutor, type AgentReadResult } from "./agent-graph.ts";
import { triageInbox } from "./triage.ts";
import type { ReconcileReaders } from "./tools.ts";
import type { AgentBudget, ProposalCandidate, ToolMatch } from "./types.ts";

/** The autonomous two-tier engine is opt-in until it has met the eval baseline (task 6.1). */
export function isAutonomousModeEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return (env.AGENT_MODE ?? "").toLowerCase() === "autonomous";
}

/** Keep only mail strictly newer than `since` (ISO). Incremental scans ride the push window. */
export function filterIncremental(messages: MailMetadata[], since?: string): MailMetadata[] {
  if (!since) return messages;
  const cut = Date.parse(since);
  if (!Number.isFinite(cut)) return messages;
  return messages.filter((m) => {
    const t = Date.parse(m.received_at);
    return !Number.isFinite(t) || t > cut;
  });
}

const MATCH_CAP = 12;

function toMatch(m: MailMetadata): ToolMatch {
  return { message_id: m.id, subject: m.subject, sender: m.sender, snippet: m.snippet, received_at: m.received_at };
}

/**
 * A read executor bound to the already-fetched scan window (metadata-only search + snippet body).
 * A Gmail-backed executor reaching beyond the window implements the same interface.
 */
export function createScanReadExecutor(messages: MailMetadata[]): AgentReadExecutor {
  const byId = new Map(messages.map((m) => [m.id, m] as const));
  return async (req): Promise<AgentReadResult> => {
    if (req.tool === "fetch") {
      const meta = byId.get(req.message_id);
      if (!meta) return { tool: "fetch", message: null };
      return {
        tool: "fetch",
        message: {
          message_id: meta.id,
          subject: meta.subject,
          sender: meta.sender,
          received_at: meta.received_at,
          content: meta.snippet, // window body; a Gmail executor returns the sanitized full body
        },
      };
    }
    const terms = req.query.toLowerCase().split(/\s+/).filter(Boolean);
    const matches = messages
      .filter((m) => {
        const hay = `${m.subject}\n${m.sender}\n${m.snippet}`.toLowerCase();
        const domain = senderDomain(m.sender);
        return terms.some((t) => hay.includes(t) || domain.includes(t));
      })
      .slice(0, MATCH_CAP)
      .map(toMatch);
    return { tool: "search_inbox", matches };
  };
}

export type TwoTierDeps = {
  // Tier-2 reasoner/agent model.
  chat: ChatFn;
  // Tier-1 triage model (defaults to `chat`).
  triageChat?: ChatFn;
  reconcile: ReconcileReaders;
  budget?: AgentBudget;
  since?: string;
  checkpointer?: BaseCheckpointSaver;
  threadId?: string;
};

export type TwoTierResult = {
  proposals: ProposalCandidate[];
  triage: { lookCount: number; skipCount: number; degraded: boolean };
};

/** Run the full funnel: incremental filter → Tier-1 triage → Tier-2 autonomous agent. */
export async function runTwoTierScan(
  rawMessages: MailMetadata[],
  deps: TwoTierDeps,
): Promise<TwoTierResult> {
  const scanned = filterIncremental(rawMessages, deps.since);
  const triageChat = deps.triageChat ?? deps.chat;
  const { look, skip, degraded } = await triageInbox(scanned, triageChat);

  const app = buildAgentGraph(
    { chat: deps.chat, readExecutor: createScanReadExecutor(look), reconcile: deps.reconcile, budget: deps.budget },
    deps.checkpointer ?? new MemorySaver(),
  );
  const final = await app.invoke(
    { rawMessages: look },
    { configurable: { thread_id: deps.threadId ?? `scan-${Date.now()}` } },
  );

  return {
    proposals: (final.proposals ?? []) as ProposalCandidate[],
    triage: { lookCount: look.length, skipCount: skip.length, degraded },
  };
}
