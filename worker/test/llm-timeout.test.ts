import { test } from "node:test";
import assert from "node:assert/strict";
import { llmRequestTimeoutMs, makeChatFn } from "../src/llm/client.ts";

test("llmRequestTimeoutMs parses the env with a 90s default", () => {
  assert.equal(llmRequestTimeoutMs(() => undefined), 90_000);
  assert.equal(llmRequestTimeoutMs(() => "30000"), 30_000);
  assert.equal(llmRequestTimeoutMs(() => "0"), 90_000); // non-positive -> default
  assert.equal(llmRequestTimeoutMs(() => "nope"), 90_000);
});

test("a timed-out model call fails fast with a clear error (so the page task retries)", async () => {
  const originalFetch = globalThis.fetch;
  const originalEnv = process.env.LLM_REQUEST_TIMEOUT_MS;
  process.env.LLM_REQUEST_TIMEOUT_MS = "200"; // keep the abort timer short for the test
  globalThis.fetch = (async () => {
    const error = new Error("The operation timed out.");
    error.name = "TimeoutError"; // what AbortSignal.timeout aborts with
    throw error;
  }) as typeof fetch;
  try {
    const chat = makeChatFn({ baseUrl: "https://example.test", apiKey: "k", model: "m" });
    await assert.rejects(
      () => chat([{ role: "user", content: "hi" }]),
      /LLM request timed out after \d+ms/,
    );
  } finally {
    globalThis.fetch = originalFetch;
    if (originalEnv === undefined) delete process.env.LLM_REQUEST_TIMEOUT_MS;
    else process.env.LLM_REQUEST_TIMEOUT_MS = originalEnv;
  }
});
