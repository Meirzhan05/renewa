import {
  authorizeToolCall,
  DEFAULT_REASONER_BUDGET,
  type MerchantScope,
  parseAssessment,
  runMerchantReasoner,
  type ToolExecutor,
  type ToolMatch,
} from "./agentic-reasoner.ts";
import type { ChatFn, ChatResult } from "./llm-client.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

const seed: ToolMatch[] = [{
  message_id: "seed-1",
  subject: "Your Anthropic receipt",
  sender: "invoice@stripe.com",
  snippet: "Payment of $20",
  received_at: "2026-08-22T10:00:00Z",
}];

function scope(overrides: Partial<MerchantScope> = {}): MerchantScope {
  return {
    canonical_merchant_key: "anthropic",
    merchant_domains: ["anthropic.com"],
    known_message_ids: new Set(["seed-1"]),
    ...overrides,
  };
}

function toolCallResult(name: string, args: Record<string, unknown>): ChatResult {
  return {
    content: "",
    toolCalls: [{ id: `call-${name}`, name, arguments: JSON.stringify(args) }],
    tokens: 10,
  };
}

function finalResult(obj: Record<string, unknown>): ChatResult {
  return { content: JSON.stringify(obj), toolCalls: [], tokens: 10 };
}

/** A ChatFn that replays a scripted list of responses in order. */
function scriptedChat(responses: ChatResult[]): { chat: ChatFn } {
  let calls = 0;
  const chat: ChatFn = (_messages, options) => {
    const index = Math.min(calls, responses.length - 1);
    calls += 1;
    // When forced to finalize (budget spent), always hand back the final response.
    if (options?.toolChoice === "none") {
      return Promise.resolve(responses[responses.length - 1]);
    }
    return Promise.resolve(responses[index]);
  };
  return { chat };
}

const completeAssessment = {
  existence: "high",
  completeness: "complete",
  missing_fields: [],
  merchant_name: "Anthropic",
  event_type: "created",
  amount: 20,
  currency: "USD",
  billing_cycle: "monthly",
  renewal_date: "2026-09-22",
  category: "work",
  confidence: 0.9,
  evidence_refs: ["seed-1"],
  abstain_reason: null,
};

Deno.test("sufficient bundle concludes with no tool call", async () => {
  const { chat } = scriptedChat([finalResult(completeAssessment)]);
  const executed: string[] = [];
  const execute: ToolExecutor = (req) => {
    executed.push(req.tool);
    return Promise.resolve({ tool: "search_inbox", matches: [] });
  };
  const result = await runMerchantReasoner({
    canonical_merchant_key: "anthropic",
    merchant_guess: "Anthropic",
    seed,
    scope: scope(),
    chat,
    execute,
  });
  assert(result.toolCalls === 0, "should not call tools when evidence suffices");
  assert(result.assessment.existence === "high", "existence should be high");
  assert(result.assessment.billing_cycle === "monthly", "cycle should survive parse");
});

Deno.test("under-confident loop gathers evidence then concludes", async () => {
  const { chat } = scriptedChat([
    toolCallResult("search_inbox", { query: "anthropic receipt" }),
    finalResult(completeAssessment),
  ]);
  let executed = 0;
  const execute: ToolExecutor = () => {
    executed += 1;
    return Promise.resolve({
      tool: "search_inbox",
      matches: [{
        message_id: "found-1",
        subject: "Anthropic renews Sep 22",
        sender: "billing@anthropic.com",
        snippet: "renews monthly",
        received_at: "2026-08-22T10:00:00Z",
      }],
    });
  };
  const s = scope();
  const result = await runMerchantReasoner({
    canonical_merchant_key: "anthropic",
    merchant_guess: "Anthropic",
    seed,
    scope: s,
    chat,
    execute,
  });
  assert(executed === 1, "tool should have executed once");
  assert(result.toolCalls === 1, "one tool call recorded");
  assert(s.known_message_ids.has("found-1"), "surfaced id registered into scope");
  assert(result.assessment.existence === "high", "final assessment emitted");
});

Deno.test("budget exhaustion yields a best-effort, reduced-confidence result", async () => {
  // Model keeps asking for tools on every auto turn; only the forced (tool_choice:none)
  // turn returns a final answer — so the loop must hit maxIterations to terminate.
  const { chat } = scriptedChat([
    toolCallResult("search_inbox", { query: "more" }),
    toolCallResult("search_inbox", { query: "again" }),
    finalResult({ ...completeAssessment, confidence: 0.9 }),
  ]);
  const execute: ToolExecutor = () =>
    Promise.resolve({ tool: "search_inbox", matches: [] });
  const result = await runMerchantReasoner({
    canonical_merchant_key: "anthropic",
    merchant_guess: "Anthropic",
    seed,
    scope: scope(),
    chat,
    execute,
    budget: { ...DEFAULT_REASONER_BUDGET, maxIterations: 2 },
  });
  assert(result.budgetExhausted, "should report budget exhaustion");
  assert(result.assessment.confidence <= 0.5, "confidence capped on exhaustion");
});

Deno.test("injection: out-of-scope fetch is never executed", async () => {
  const { chat } = scriptedChat([
    toolCallResult("fetch", { message_id: "evil-id-from-email-body" }),
    finalResult({ ...completeAssessment, existence: "low", abstain_reason: "insufficient" }),
  ]);
  let executed = 0;
  const execute: ToolExecutor = () => {
    executed += 1;
    return Promise.resolve({ tool: "fetch", message: null });
  };
  const result = await runMerchantReasoner({
    canonical_merchant_key: "anthropic",
    merchant_guess: "Anthropic",
    seed,
    scope: scope(),
    chat,
    execute,
  });
  assert(executed === 0, "out-of-scope fetch must not reach the executor");
  assert(result.assessment.existence === "low", "loop still terminates with an assessment");
});

Deno.test("authorizeToolCall rejects out-of-scope fetch id", () => {
  const decision = authorizeToolCall(
    "fetch",
    JSON.stringify({ message_id: "not-surfaced" }),
    scope(),
  );
  assert(!decision.ok, "unknown id must be rejected");
  assert(!decision.ok && decision.reason === "out_of_scope_message", "correct reason");
});

Deno.test("authorizeToolCall rejects get_more for a foreign sender", () => {
  const decision = authorizeToolCall(
    "get_more",
    JSON.stringify({ sender: "attacker@evil.com" }),
    scope(),
  );
  assert(!decision.ok, "foreign sender must be rejected");
  assert(
    !decision.ok && decision.reason === "sender_not_in_merchant_scope",
    "correct reason",
  );
});

Deno.test("authorizeToolCall allows a merchant-scoped get_more and normalizes domain", () => {
  const decision = authorizeToolCall(
    "get_more",
    JSON.stringify({ sender: "billing@anthropic.com" }),
    scope(),
  );
  assert(decision.ok, "merchant sender must be allowed");
  assert(
    decision.ok && decision.request.tool === "get_more" &&
      decision.request.sender === "anthropic.com",
    "domain normalized",
  );
});

Deno.test("ungrounded/invalid amount is coerced to null, never invented", () => {
  const parsed = parseAssessment(
    JSON.stringify({ ...completeAssessment, amount: "twenty dollars" }),
    "anthropic",
    "Anthropic",
  );
  assert(parsed.amount === null, "non-numeric amount must be dropped");
  assert(parsed.missing_fields.includes("amount"), "missing amount recomputed");
  assert(parsed.completeness === "incomplete", "completeness reflects the gap");
});
