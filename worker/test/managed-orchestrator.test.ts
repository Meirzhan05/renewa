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
