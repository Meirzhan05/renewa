import assert from "node:assert/strict";
import { test } from "node:test";
import type { Pool } from "pg";
import { heartbeatOnce } from "../src/trigger/analyze-inbox-page.ts";

test("heartbeatOnce swallows a rejecting query and never rejects", async () => {
  let called = 0;
  const pool = {
    query: async () => {
      called += 1;
      throw new Error("timeout exceeded when trying to connect");
    },
  } as unknown as Pool;
  // A DB blip in the fire-and-forget heartbeat must never become an unhandled rejection that would
  // crash the task; heartbeatOnce catches internally and resolves.
  await assert.doesNotReject(heartbeatOnce(pool, "exec-1"));
  assert.equal(called, 1);
});

test("heartbeatOnce issues the heartbeat with the execution id", async () => {
  const calls: unknown[][] = [];
  const pool = {
    query: async (...args: unknown[]) => {
      calls.push(args);
      return { rows: [] };
    },
  } as unknown as Pool;
  await heartbeatOnce(pool, "exec-42");
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]?.[1], ["exec-42"]);
});
