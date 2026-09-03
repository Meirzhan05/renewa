import assert from "node:assert/strict";
import { test } from "node:test";
import { orchestrateManagedScan } from "../src/trigger/scan-inbox-run.ts";

test("managed scan fetches all pages sequentially and leaves analysis to the dispatcher", async () => {
  const calls: string[] = [];
  const steps = [
    { cancelled: false, hasNextPage: true, pageId: "page-1" },
    { cancelled: false, hasNextPage: false, pageId: "page-2" },
  ];
  const result = await orchestrateManagedScan(
    { version: 2, scanRunId: "run-1", connectionId: "connection-1" },
    async () => {
      calls.push("fetch");
      const step = steps.shift();
      assert.ok(step);
      return step;
    },
  );
  assert.deepEqual(calls, ["fetch", "fetch"]);
  assert.deepEqual(result, { cancelled: false, pagesProcessed: 2 });
});

test("cancellation during fetch stops without admitting further pages", async () => {
  const result = await orchestrateManagedScan(
    { version: 2, scanRunId: "run-1", connectionId: "connection-1" },
    async () => ({ cancelled: true, hasNextPage: false, pageId: null }),
  );
  assert.deepEqual(result, { cancelled: true, pagesProcessed: 0 });
});

// A page the Edge Function re-queued behind a backoff comes back with `retryAfterMs` and no pageId.
// The wait has to actually happen: the claim honours `available_at`, so looping straight back would
// spin without claiming anything — and before that filter existed it re-took the same page instantly
// and burned every attempt in milliseconds, hammering a provider that had asked us to slow down.
test("a deferred page is waited out before the next attempt", async () => {
  const slept: number[] = [];
  const steps = [
    { cancelled: false, hasNextPage: true, pageId: "page-1" },
    { cancelled: false, hasNextPage: true, pageId: null, retryAfterMs: 2000 },
    { cancelled: false, hasNextPage: true, pageId: null, retryAfterMs: 4000 },
    { cancelled: false, hasNextPage: false, pageId: "page-2" },
  ];
  const result = await orchestrateManagedScan(
    { version: 2, scanRunId: "run-1", connectionId: "connection-1" },
    async () => {
      const step = steps.shift();
      assert.ok(step);
      return step;
    },
    async (ms) => {
      slept.push(ms);
    },
  );

  assert.deepEqual(slept, [2000, 4000], "each deferral must be waited out, and backoff grows");
  // A retry is not a page: only real pages count toward the run's progress.
  assert.deepEqual(result, { cancelled: false, pagesProcessed: 2 });
});

test("the ordinary path never waits", async () => {
  const slept: number[] = [];
  const steps = [
    { cancelled: false, hasNextPage: true, pageId: "page-1" },
    { cancelled: false, hasNextPage: false, pageId: "page-2" },
  ];
  await orchestrateManagedScan(
    { version: 2, scanRunId: "run-1", connectionId: "connection-1" },
    async () => {
      const step = steps.shift();
      assert.ok(step);
      return step;
    },
    async (ms) => {
      slept.push(ms);
    },
  );
  assert.deepEqual(slept, [], "a scan with no deferrals must not pause between pages");
});

test("a cancelled scan does not wait out a pending backoff", async () => {
  const slept: number[] = [];
  await orchestrateManagedScan(
    { version: 2, scanRunId: "run-1", connectionId: "connection-1" },
    async () => ({ cancelled: true, hasNextPage: true, pageId: null, retryAfterMs: 8000 }),
    async (ms) => {
      slept.push(ms);
    },
  );
  assert.deepEqual(slept, [], "cancellation must win over a pending retry");
});
