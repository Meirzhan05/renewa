// Shared OpenAI-compatible chat client for the two-tier discovery pipeline.
// Tier-1 (wide classifier) and tier-2 (per-merchant reasoner + verifier) share one
// request/parse/timeout path. The engine modules depend only on the `ChatFn` interface
// so they stay unit-testable with an injected fake model.

export type ChatRole = "system" | "user" | "assistant" | "tool";

export type ChatMessage = {
  role: ChatRole;
  content: string;
  // Present on assistant turns that requested tools, echoed back so the model can
  // correlate its tool results.
  tool_calls?: RawToolCall[];
  // Present on `role: "tool"` turns replying to a specific tool call.
  tool_call_id?: string;
  name?: string;
};

export type RawToolCall = {
  id: string;
  type: "function";
  function: { name: string; arguments: string };
};

export type ToolCall = { id: string; name: string; arguments: string };

export type ChatResult = {
  content: string | null;
  toolCalls: ToolCall[];
  // Best-effort token accounting for budget enforcement; 0 when the provider omits it.
  tokens: number;
};

export type ToolSchema = {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
};

export type ChatOptions = {
  maxTokens?: number;
  temperature?: number;
  jsonResponse?: boolean;
  tools?: ToolSchema[];
  // "auto" lets the model decide; "none" forces a final answer (used to force
  // termination when the loop budget is spent).
  toolChoice?: "auto" | "none";
  signal?: AbortSignal;
};

export type ChatFn = (
  messages: ChatMessage[],
  options?: ChatOptions,
) => Promise<ChatResult>;

export type LlmConfig = {
  baseUrl: string; // e.g. https://api.deepseek.com/v1
  apiKey: string;
  model: string;
};

type EnvLookup = (key: string) => string | undefined;

function denoEnv(key: string): string | undefined {
  // Guard so this module can be imported in non-Deno test contexts if needed.
  return (globalThis as { Deno?: { env: { get(k: string): string | undefined } } })
    .Deno?.env.get(key);
}

/** Tier-2 reasoner/verifier config. Always DeepSeek; throws if the key is missing. */
export function resolveReasonerConfig(env: EnvLookup = denoEnv): LlmConfig {
  const apiKey = env("DEEPSEEK_API_KEY");
  if (!apiKey) throw new Error("DEEPSEEK_API_KEY is not set");
  return {
    baseUrl: env("DEEPSEEK_BASE_URL") ?? "https://api.deepseek.com/v1",
    apiKey,
    model: env("DEEPSEEK_MODEL") ?? "deepseek-chat",
  };
}

/**
 * Tier-1 classifier config. Uses the dedicated cheap/fast model when `CLASSIFIER_*`
 * is configured, otherwise falls back to the reasoner (DeepSeek) config so the
 * pipeline degrades rather than breaks. Returns null only when neither is available.
 */
export function resolveClassifierConfig(env: EnvLookup = denoEnv): LlmConfig | null {
  const apiKey = env("CLASSIFIER_API_KEY");
  const model = env("CLASSIFIER_MODEL");
  const baseUrl = env("CLASSIFIER_BASE_URL");
  if (apiKey && model && baseUrl) {
    return { baseUrl, apiKey, model };
  }
  // Fall back to DeepSeek if the classifier tier is not separately configured.
  try {
    return resolveReasonerConfig(env);
  } catch {
    return null;
  }
}

/** Whether the agentic pipeline is enabled for this scan. Defaults OFF. */
export function agenticDiscoveryEnabled(env: EnvLookup = denoEnv): boolean {
  return (env("AGENTIC_DISCOVERY") ?? "").toLowerCase() === "on";
}

/** Build a real network-backed ChatFn for a resolved config. */
export function makeChatFn(config: LlmConfig): ChatFn {
  const url = `${config.baseUrl.replace(/\/$/, "")}/chat/completions`;
  return async (messages, options = {}) => {
    const body: Record<string, unknown> = {
      model: config.model,
      messages,
      temperature: options.temperature ?? 0,
      max_tokens: options.maxTokens ?? 1_200,
    };
    if (options.jsonResponse) body.response_format = { type: "json_object" };
    if (options.tools && options.tools.length > 0) {
      body.tools = options.tools.map((tool) => ({
        type: "function",
        function: {
          name: tool.name,
          description: tool.description,
          parameters: tool.parameters,
        },
      }));
      body.tool_choice = options.toolChoice ?? "auto";
    }
    const response = await fetch(url, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${config.apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
      signal: options.signal,
    });
    const payload = await response.json();
    if (!response.ok) {
      throw new Error(payload?.error?.message ?? "LLM request failed");
    }
    return parseChatPayload(payload);
  };
}

/** Parse an OpenAI-compatible completion payload into a normalized ChatResult. */
export function parseChatPayload(payload: unknown): ChatResult {
  const record = (typeof payload === "object" && payload !== null)
    ? payload as Record<string, unknown>
    : {};
  const choices = Array.isArray(record.choices) ? record.choices : [];
  const message = (choices[0] as { message?: unknown })?.message as
    | Record<string, unknown>
    | undefined;
  const content = typeof message?.content === "string" ? message.content : null;
  const rawToolCalls = Array.isArray(message?.tool_calls)
    ? message!.tool_calls as RawToolCall[]
    : [];
  const toolCalls: ToolCall[] = rawToolCalls
    .filter((call) => call?.function?.name)
    .map((call) => ({
      id: String(call.id ?? call.function.name),
      name: String(call.function.name),
      arguments: typeof call.function.arguments === "string"
        ? call.function.arguments
        : JSON.stringify(call.function.arguments ?? {}),
    }));
  const usage = record.usage as { total_tokens?: unknown } | undefined;
  const tokens = typeof usage?.total_tokens === "number" ? usage.total_tokens : 0;
  return { content, toolCalls, tokens };
}
