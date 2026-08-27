// The agentic discovery pipeline as a LangGraph state machine. One graph processes a whole scan:
// classify → group → then walk each merchant through reason ↔ tools ↔ verify ↔ route. A verified,
// confident merchant is surfaced as a candidate the person confirms; everything else is a
// near-miss. Run state is checkpointed to Postgres in the worker so a long scan survives restarts.
// Model output is untrusted: it PROPOSES tool calls; `authorizeToolCall` AUTHORIZES them against
// merchant scope, and the budget guarantees termination.

import { Annotation, END, START, StateGraph } from "@langchain/langgraph";
import type { BaseCheckpointSaver } from "@langchain/langgraph";
import {
  admitCandidate,
  classifyCandidates,
  groupByMerchant,
  type MerchantBundle,
} from "../domain/classifier.ts";
import { computeCadenceFeatures, reconcileRecurrence } from "../domain/cadence.ts";
import { senderDomain, type MailMetadata } from "../domain/email.ts";
import {
  assessmentSchemaHint,
  authorizeToolCall,
  DEFAULT_REASONER_BUDGET,
  finalizeAssessment,
  parseAssessment,
  reasonerSystemPrompt,
  reasonerToolSchemas,
  type MerchantAssessment,
  type MerchantScope,
  type ReasonerBudget,
  type ToolExecutor,
  type ToolMatch,
} from "../domain/reasoner.ts";
import { DEFAULT_ROUTING_OPTIONS, routeAssessment, type RoutingOptions } from "../domain/routing.ts";
import { verifyAssessment } from "../domain/verify.ts";
import type { ChatFn, ChatMessage } from "../llm/client.ts";

export type RouteOutcome =
  | { kind: "present"; assessment: MerchantAssessment }
  | { kind: "near_miss"; reason: string; assessment: MerchantAssessment };

export type GraphDeps = {
  // Tier-2 reasoner/verifier model.
  chat: ChatFn;
  // Optional cheaper tier-1 classifier; defaults to `chat`.
  classifierChat?: ChatFn;
  // Performs an AUTHORIZED read-only tool request. `rawMessages` is passed for local fetch.
  executeTool: ToolExecutor;
  budget?: ReasonerBudget;
  routing?: RoutingOptions;
};

const StateAnnotation = Annotation.Root({
  // Input: all fetched message metadata for this scan.
  rawMessages: Annotation<MailMetadata[]>({ default: () => [], reducer: (_p, n) => n }),
  // Per-merchant bundles produced by classify+group.
  bundles: Annotation<MerchantBundle[]>({ default: () => [], reducer: (_p, n) => n }),
  cursor: Annotation<number>({ default: () => 0, reducer: (_p, n) => n }),
  // Accumulated outcomes — the only channel that grows across merchants.
  results: Annotation<RouteOutcome[]>({ default: () => [], reducer: (p, n) => p.concat(n) }),

  // Current-merchant working set (reset by `select`).
  canonical: Annotation<string>({ default: () => "", reducer: (_p, n) => n }),
  merchantGuess: Annotation<string>({ default: () => "", reducer: (_p, n) => n }),
  seed: Annotation<ToolMatch[]>({ default: () => [], reducer: (_p, n) => n }),
  scopeDomains: Annotation<string[]>({ default: () => [], reducer: (_p, n) => n }),
  knownIds: Annotation<string[]>({ default: () => [], reducer: (_p, n) => n }),
  messages: Annotation<ChatMessage[]>({ default: () => [], reducer: (_p, n) => n }),
  iters: Annotation<number>({ default: () => 0, reducer: (_p, n) => n }),
  toolCalls: Annotation<number>({ default: () => 0, reducer: (_p, n) => n }),
  fetches: Annotation<number>({ default: () => 0, reducer: (_p, n) => n }),
  tokens: Annotation<number>({ default: () => 0, reducer: (_p, n) => n }),
  deadline: Annotation<number>({ default: () => 0, reducer: (_p, n) => n }),
  assessment: Annotation<MerchantAssessment | null>({ default: () => null, reducer: (_p, n) => n }),
  toolPending: Annotation<boolean>({ default: () => false, reducer: (_p, n) => n }),
  routeKind: Annotation<string>({ default: () => "", reducer: (_p, n) => n }),
  routeReason: Annotation<string | null>({ default: () => null, reducer: (_p, n) => n }),
});

export type GraphState = typeof StateAnnotation.State;

function toToolMatch(meta: MailMetadata): ToolMatch {
  return {
    message_id: meta.id,
    subject: meta.subject,
    sender: meta.sender,
    snippet: meta.snippet,
    received_at: meta.received_at,
  };
}

function scopeFromState(state: GraphState): MerchantScope {
  return {
    canonical_merchant_key: state.canonical,
    merchant_domains: state.scopeDomains,
    known_message_ids: new Set(state.knownIds),
  };
}

export function buildGraph(deps: GraphDeps, checkpointer?: BaseCheckpointSaver) {
  const budget = deps.budget ?? DEFAULT_REASONER_BUDGET;
  const classifierChat = deps.classifierChat ?? deps.chat;

  async function classifyNode(state: GraphState): Promise<Partial<GraphState>> {
    const classifications = await classifyCandidates(state.rawMessages, classifierChat);
    const admitted = state.rawMessages
      .filter((m) => admitCandidate(classifications.get(m.id), m))
      .map((m) => ({ meta: m, merchant_guess: classifications.get(m.id)?.merchant_guess ?? "" }));
    return { bundles: groupByMerchant(admitted), cursor: 0 };
  }

  function selectNode(state: GraphState): Partial<GraphState> {
    const bundle = state.bundles[state.cursor];
    if (!bundle) return {};
    const metaById = new Map(state.rawMessages.map((m) => [m.id, m] as const));
    const seed: ToolMatch[] = [];
    for (const id of bundle.message_ids) {
      const meta = metaById.get(id);
      if (meta) seed.push(toToolMatch(meta));
    }
    const scopeDomains = [...new Set(seed.map((s) => senderDomain(s.sender)).filter(Boolean))];
    const knownIds = [...new Set(state.rawMessages.map((m) => m.id))];
    const messages: ChatMessage[] = [
      { role: "system", content: reasonerSystemPrompt() },
      {
        role: "user",
        content: JSON.stringify({
          schema_version: "merchant-assessment-v1",
          merchant_guess: bundle.merchant_guess,
          canonical_merchant_key: bundle.canonical_merchant_key,
          evidence: seed.map((m) => ({
            message_id: m.message_id,
            subject: m.subject.slice(0, 200),
            sender: m.sender.slice(0, 160),
            snippet: m.snippet.slice(0, 200),
            received_at: m.received_at,
          })),
          instruction:
            "Decide whether this is an active paid subscription (not repeated one-off " +
            "purchases). Use tools to gather more evidence if under-confident. When done, reply " +
            "with ONLY the assessment JSON.",
          assessment_schema: assessmentSchemaHint(),
        }),
      },
    ];
    return {
      canonical: bundle.canonical_merchant_key,
      merchantGuess: bundle.merchant_guess,
      seed,
      scopeDomains,
      knownIds,
      messages,
      iters: 0,
      toolCalls: 0,
      fetches: 0,
      tokens: 0,
      assessment: null,
      toolPending: false,
      deadline: Date.now() + budget.wallClockMs,
    };
  }

  async function reasonNode(state: GraphState): Promise<Partial<GraphState>> {
    const outOfBudget =
      state.iters >= budget.maxIterations ||
      state.tokens >= budget.maxTokens ||
      state.toolCalls >= budget.maxToolCalls ||
      Date.now() > state.deadline;
    const forceFinal = outOfBudget;

    const result = await deps.chat(state.messages, {
      temperature: 0,
      maxTokens: 1_400,
      tools: forceFinal ? undefined : reasonerToolSchemas(),
      toolChoice: forceFinal ? "none" : "auto",
      jsonResponse: forceFinal,
    });
    const tokens = state.tokens + result.tokens;
    const iters = state.iters + 1;

    if (!forceFinal && result.toolCalls.length > 0) {
      const assistant: ChatMessage = {
        role: "assistant",
        content: result.content ?? "",
        tool_calls: result.toolCalls.map((c) => ({
          id: c.id,
          type: "function",
          function: { name: c.name, arguments: c.arguments },
        })),
      };
      return { messages: [...state.messages, assistant], iters, tokens, toolPending: true };
    }

    const parsed = parseAssessment(result.content, state.canonical, state.merchantGuess);
    const assessment = finalizeAssessment(parsed, outOfBudget);
    return {
      messages: [...state.messages, { role: "assistant", content: result.content ?? "" }],
      iters,
      tokens,
      toolPending: false,
      assessment,
    };
  }

  async function toolsNode(state: GraphState): Promise<Partial<GraphState>> {
    const scope = scopeFromState(state);
    const last = state.messages[state.messages.length - 1];
    const calls = last?.tool_calls ?? [];
    let toolCalls = state.toolCalls;
    let fetches = state.fetches;
    const knownIds = new Set(state.knownIds);
    const newMessages: ChatMessage[] = [];

    for (const call of calls) {
      const auth = authorizeToolCall(call.function.name, call.function.arguments, scope);
      let payload: Record<string, unknown>;
      if (!auth.ok) {
        payload = { error: auth.reason };
      } else if (
        toolCalls >= budget.maxToolCalls ||
        fetches >= budget.maxFetches ||
        Date.now() > state.deadline
      ) {
        payload = { error: "budget_exhausted" };
      } else {
        toolCalls += 1;
        if (auth.request.tool === "fetch") fetches += 1;
        try {
          const res = await deps.executeTool(auth.request);
          if (res.tool === "search_inbox" || res.tool === "get_more") {
            for (const m of res.matches) knownIds.add(m.message_id);
          }
          payload = res as unknown as Record<string, unknown>;
        } catch {
          payload = { error: "tool_execution_failed" };
        }
      }
      newMessages.push({
        role: "tool",
        tool_call_id: call.id,
        name: call.function.name,
        content: JSON.stringify(payload),
      });
    }

    return {
      messages: [...state.messages, ...newMessages],
      toolCalls,
      fetches,
      knownIds: [...knownIds],
    };
  }

  async function verifyNode(state: GraphState): Promise<Partial<GraphState>> {
    const evidenceTexts = state.seed.map((m) => `${m.subject}\n${m.snippet}`);
    let assessment = state.assessment ?? parseAssessment(null, state.canonical, state.merchantGuess);
    assessment = await verifyAssessment(assessment, evidenceTexts, deps.chat);
    // Precision guard: reconcile the model's recurrence claim with deterministic cadence evidence,
    // so repeated one-off purchases are demoted before routing.
    assessment = reconcileRecurrence(assessment, computeCadenceFeatures(state.seed));
    return { assessment };
  }

  function routeNode(state: GraphState): Partial<GraphState> {
    const assessment = state.assessment!;
    const outcome = routeAssessment(assessment, deps.routing ?? DEFAULT_ROUTING_OPTIONS);
    return {
      routeKind: outcome.kind,
      routeReason: outcome.kind === "near_miss" ? outcome.reason : null,
    };
  }

  function presentNode(state: GraphState): Partial<GraphState> {
    return {
      results: [{ kind: "present", assessment: state.assessment! }],
      cursor: state.cursor + 1,
    };
  }

  function nearMissNode(state: GraphState): Partial<GraphState> {
    return {
      results: [
        { kind: "near_miss", reason: state.routeReason ?? "near_miss", assessment: state.assessment! },
      ],
      cursor: state.cursor + 1,
    };
  }

  const graph = new StateGraph(StateAnnotation)
    .addNode("classify", classifyNode)
    .addNode("select", selectNode)
    .addNode("reason", reasonNode)
    .addNode("tools", toolsNode)
    .addNode("verify", verifyNode)
    .addNode("route", routeNode)
    .addNode("present", presentNode)
    .addNode("nearmiss", nearMissNode)
    .addEdge(START, "classify")
    .addEdge("classify", "select")
    .addConditionalEdges(
      "select",
      (s: GraphState) => (s.cursor < s.bundles.length ? "reason" : END),
      ["reason", END],
    )
    .addConditionalEdges("reason", (s: GraphState) => (s.toolPending ? "tools" : "verify"), [
      "tools",
      "verify",
    ])
    .addEdge("tools", "reason")
    .addEdge("verify", "route")
    .addConditionalEdges(
      "route",
      (s: GraphState) => (s.routeKind === "present" ? "present" : "nearmiss"),
      ["present", "nearmiss"],
    )
    .addEdge("present", "select")
    .addEdge("nearmiss", "select");

  return graph.compile(checkpointer ? { checkpointer } : undefined);
}
