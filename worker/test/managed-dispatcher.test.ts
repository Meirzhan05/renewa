import assert from "node:assert/strict";
import { test } from "node:test";
import type { Pool } from "pg";
import { dispatchReservedInboxPages, reserveInboxPages } from "../src/trigger/dispatch-inbox-pages.ts";

test("dispatcher records a runtime id and releases only failed submissions", async () => {
  const calls: Array<{ text: string; values: unknown[] }> = [];
  const pool = { async query(text: string, values: unknown[]) {
    calls.push({ text, values });
    return { rows: text.includes("attach") ? [{ attached: true }] : [] };
  } } as unknown as Pool;
  const result = await dispatchReservedInboxPages(pool, [
    { executionId: "execution-1", scanRunId: "run-1", pageId: "page-1", dispatchToken: "token-1" },
    { executionId: "execution-2", scanRunId: "run-1", pageId: "page-2", dispatchToken: "token-2" },
  ], async (payload) => {
    if (payload.pageId === "page-2") throw new Error("runtime unavailable");
    return { id: "trigger-run-1" };
  });
  assert.deepEqual(result, { dispatched: 1, released: 1 });
  assert.equal(calls.filter((call) => call.text.includes("attach_inbox_agent_runtime")).length, 1);
  assert.equal(calls.filter((call) => call.text.includes("release_inbox_agent_dispatch")).length, 1);
});

test("dispatcher releases a stale reservation rather than treating it as submitted", async () => {
  const calls: string[] = [];
  const pool = { async query(text: string) {
    calls.push(text);
    return { rows: text.includes("attach") ? [{ attached: false }] : [] };
  } } as unknown as Pool;
  const result = await dispatchReservedInboxPages(pool, [
    { executionId: "execution-1", scanRunId: "run-1", pageId: "page-1", dispatchToken: "stale-token" },
  ], async () => ({ id: "trigger-run-1" }));

  assert.deepEqual(result, { dispatched: 0, released: 1 });
  assert.equal(calls.filter((text) => text.includes("release_inbox_agent_dispatch")).length, 1);
});

test("dispatcher forwards conservative global, provider, and per-user admission budgets", async () => {
  let values: unknown[] = [];
  const pool = { async query(_text: string, suppliedValues: unknown[]) {
    values = suppliedValues;
    return { rows: [] };
  } } as unknown as Pool;

  await reserveInboxPages(pool, 3);
  assert.deepEqual(values, [3, 4, 4, 4, 1, 120]);
});
