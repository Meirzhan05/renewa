import assert from "node:assert/strict";
import { test } from "node:test";
import { orchestrateManagedScan } from "../src/trigger/scan-inbox-run.ts";

test("managed scan waits for each page analysis before fetching the next page", async () => {
  const calls: string[] = [];
  const steps = [
    { cancelled: false, hasNextPage: true, pageId: "page-1" },
    { cancelled: false, hasNextPage: false, pageId: "page-2" },
  ];
  const result = await orchestrateManagedScan(
    { version: 1, scanRunId: "run-1", connectionId: "connection-1" },
    async () => {
      calls.push("fetch");
      const step = steps.shift();
      assert.ok(step);
      return step;
    },
    async (page) => {
      calls.push(`analyze:${page.pageId}`);
      return { cancelled: false };
    },
  );
  assert.deepEqual(calls, ["fetch", "analyze:page-1", "fetch", "analyze:page-2"]);
  assert.deepEqual(result, { cancelled: false, pagesProcessed: 2 });
});

test("managed scan stops before scheduling another page after cancellation", async () => {
  const result = await orchestrateManagedScan(
    { version: 1, scanRunId: "run-1", connectionId: "connection-1" },
    async () => ({ cancelled: false, hasNextPage: true, pageId: "page-1" }),
    async () => ({ cancelled: true }),
  );
  assert.deepEqual(result, { cancelled: true, pagesProcessed: 0 });
});
