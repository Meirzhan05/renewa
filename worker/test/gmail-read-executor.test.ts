import { test } from "node:test";
import assert from "node:assert/strict";
import { createGmailBodyReadExecutor } from "../src/agent/gmail-read-executor.ts";
import type { MailMetadata } from "../src/domain/email.ts";

const b64 = (s: string): string => Buffer.from(s, "utf8").toString("base64url");

const window: MailMetadata[] = [
  {
    id: "gmail-abc",
    subject: "Your receipt from Anthropic",
    sender: "receipts@stripe.com",
    received_at: "2026-08-22T00:00:00Z",
    snippet: "Receipt from Anthropic PBC",
  },
  {
    id: "gmail-def",
    subject: "OpenAI invoice",
    sender: "billing@openai.com",
    received_at: "2026-08-23T00:00:00Z",
    snippet: "OpenAI",
  },
];

/** Swap global fetch for the duration of `fn`, restoring it afterward. */
async function withFetch(
  impl: (url: string, init?: RequestInit) => Promise<unknown>,
  fn: () => Promise<void>,
): Promise<void> {
  const original = globalThis.fetch;
  globalThis.fetch = ((url: string, init?: RequestInit) => impl(url, init)) as typeof fetch;
  try {
    await fn();
  } finally {
    globalThis.fetch = original;
  }
}

test("fetch returns the sanitized full body and calls Gmail with the bare id + bearer token", async () => {
  let seenUrl = "";
  let seenAuth = "";
  await withFetch(
    (url, init) => {
      seenUrl = url;
      seenAuth = String((init?.headers as Record<string, string>)?.Authorization ?? "");
      return Promise.resolve({
        ok: true,
        json: () =>
          Promise.resolve({
            payload: {
              mimeType: "text/plain",
              body: { data: b64("Amount paid $20.00 — your subscription renews monthly") },
            },
          }),
      });
    },
    async () => {
      const exec = createGmailBodyReadExecutor("tok-123", window);
      const res = await exec({ tool: "fetch", message_id: "gmail-abc" });
      assert.equal(res.tool, "fetch");
      assert.equal(
        res.tool === "fetch" ? res.message?.content : null,
        "Amount paid $20.00 — your subscription renews monthly",
      );
    },
  );
  // The `gmail-` prefix is stripped before hitting the API, and the token rides as a bearer.
  assert.match(seenUrl, /\/messages\/abc\?format=full$/);
  assert.doesNotMatch(seenUrl, /gmail-abc/);
  assert.equal(seenAuth, "Bearer tok-123");
});

test("fetch falls back to the snippet on a non-2xx response", async () => {
  await withFetch(
    () => Promise.resolve({ ok: false, status: 401, json: () => Promise.resolve({}) }),
    async () => {
      const exec = createGmailBodyReadExecutor("tok-123", window);
      const res = await exec({ tool: "fetch", message_id: "gmail-abc" });
      assert.equal(res.tool === "fetch" ? res.message?.content : null, "Receipt from Anthropic PBC");
    },
  );
});

test("fetch falls back to the snippet when the request throws", async () => {
  await withFetch(
    () => Promise.reject(new Error("network down")),
    async () => {
      const exec = createGmailBodyReadExecutor("tok-123", window);
      const res = await exec({ tool: "fetch", message_id: "gmail-def" });
      assert.equal(res.tool === "fetch" ? res.message?.content : null, "OpenAI");
    },
  );
});

test("fetch of an unknown id returns a null message and never calls the network", async () => {
  let called = false;
  await withFetch(
    () => {
      called = true;
      return Promise.resolve({ ok: true, json: () => Promise.resolve({}) });
    },
    async () => {
      const exec = createGmailBodyReadExecutor("tok-123", window);
      const res = await exec({ tool: "fetch", message_id: "gmail-missing" });
      assert.equal(res.tool === "fetch" ? res.message : "x", null);
    },
  );
  assert.equal(called, false);
});

test("search_inbox matches over the window by keyword and sender domain", async () => {
  const exec = createGmailBodyReadExecutor("tok-123", window);
  const bySubject = await exec({ tool: "search_inbox", query: "anthropic" });
  assert.deepEqual(
    bySubject.tool === "search_inbox" ? bySubject.matches.map((m) => m.message_id) : [],
    ["gmail-abc"],
  );
  const byDomain = await exec({ tool: "search_inbox", query: "openai" });
  assert.deepEqual(
    byDomain.tool === "search_inbox" ? byDomain.matches.map((m) => m.message_id) : [],
    ["gmail-def"],
  );
});
