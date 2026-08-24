// Shared test doubles. `fakeChat` routes each call to the right canned response by sniffing the
// schema marker embedded in the prompt (classifier / reasoner / verifier), so one fake serves the
// whole graph regardless of call order. No network, fully deterministic.

import { senderLabel, type MailMetadata } from "../src/domain/email.ts";
import type { ChatFn, ChatMessage, ChatResult } from "../src/llm/client.ts";
import type { ToolExecutor } from "../src/domain/reasoner.ts";

export type FakeChatHandlers = {
  // Return the classifier JSON for a batch; defaults to "everything relevant".
  classify?: (messages: ChatMessage[]) => string;
  // Return the merchant-assessment JSON, keyed off canonical_merchant_key in the prompt.
  assess: (canonical: string, messages: ChatMessage[]) => string;
  // Return the verification verdict; defaults to "grounds every asserted field".
  verify?: (messages: ChatMessage[]) => string;
};

function promptText(messages: ChatMessage[]): string {
  return messages.map((m) => m.content).join("\n");
}

function readUserJson(messages: ChatMessage[]): Record<string, unknown> {
  const user = [...messages].reverse().find((m) => m.role === "user");
  if (!user) return {};
  try {
    return JSON.parse(user.content) as Record<string, unknown>;
  } catch {
    return {};
  }
}

export function defaultClassify(messages: ChatMessage[]): string {
  const body = readUserJson(messages);
  const rows = Array.isArray(body.messages) ? (body.messages as Array<Record<string, unknown>>) : [];
  const results = rows.map((row) => ({
    message_id: String(row.message_id),
    relevant: true,
    confidence: 0.9,
    merchant: senderLabel(String(row.sender ?? "")),
  }));
  return JSON.stringify({ results });
}

export function defaultVerify(messages: ChatMessage[]): string {
  const body = readUserJson(messages);
  const asserted = (body.asserted_fields ?? {}) as Record<string, unknown>;
  return JSON.stringify({ existence_supported: true, grounded_fields: Object.keys(asserted) });
}

export function fakeChat(handlers: FakeChatHandlers): ChatFn {
  return async (messages): Promise<ChatResult> => {
    const text = promptText(messages);
    if (text.includes("candidate-classification-v1")) {
      const classify = handlers.classify ?? defaultClassify;
      return { content: classify(messages), toolCalls: [], tokens: 10 };
    }
    if (text.includes("assessment-verification-v1")) {
      const verify = handlers.verify ?? defaultVerify;
      return { content: verify(messages), toolCalls: [], tokens: 5 };
    }
    if (text.includes("merchant-assessment-v1")) {
      const body = readUserJson(messages);
      const canonical = String(body.canonical_merchant_key ?? "");
      return { content: handlers.assess(canonical, messages), toolCalls: [], tokens: 20 };
    }
    return { content: "{}", toolCalls: [], tokens: 1 };
  };
}

export function mail(partial: Partial<MailMetadata> & { id: string }): MailMetadata {
  return {
    subject: "",
    sender: "noreply@example.com",
    snippet: "",
    received_at: "2026-08-01T00:00:00Z",
    ...partial,
  };
}

/** Executor that serves nothing new — the reason loop must decide on the seed alone. */
export const emptyExecutor: ToolExecutor = async (request) => {
  if (request.tool === "fetch") return { tool: "fetch", message: null };
  if (request.tool === "get_more") return { tool: "get_more", matches: [] };
  return { tool: "search_inbox", matches: [] };
};
