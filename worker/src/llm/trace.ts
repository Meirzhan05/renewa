// Opt-in LangSmith tracing. LangGraph auto-traces node execution when LANGSMITH_TRACING=true, but
// our model calls go through a raw fetch (makeChatFn), not a LangChain model — so they would show
// up as opaque time inside a node. Wrapping the ChatFn with `traceable` records each call as its
// own child span (prompt in, assistant + token count out). Entirely inert unless tracing is on, so
// tests and normal runs are unaffected and no data leaves the process.

import { traceable } from "langsmith/traceable";
import type { ChatFn } from "./client.ts";

export function tracingEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  const flag = env.LANGSMITH_TRACING ?? env.LANGCHAIN_TRACING_V2 ?? "";
  return flag.toLowerCase() === "true";
}

/** Wrap a ChatFn so each call is a named LangSmith span. No-op when tracing is disabled. */
export function withTracing(chat: ChatFn, name: string): ChatFn {
  if (!tracingEnabled()) return chat;
  const traced = traceable((messages: Parameters<ChatFn>[0], options?: Parameters<ChatFn>[1]) => chat(messages, options), {
    name,
    run_type: "llm",
  });
  return ((messages, options) => traced(messages, options)) as ChatFn;
}
