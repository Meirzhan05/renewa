import assert from "node:assert/strict";
import { test } from "node:test";
import { orchestrateManagedScan, pageAnalysisBatchItems } from "../src/trigger/scan-inbox-run.ts";
import {
  pageAnalysisConcurrencyKey,
  pageAnalysisIdempotencyKey,
  type AnalyzeInboxPagePayload,
} from "../src/managed/contracts.ts";

test("managed scan fetches all pages sequentially, then analyzes them in one batch", async () => {
  const calls: string[] = [];
  const steps = [
    { cancelled: false, hasNextPage: true, pageId: "page-1" },
    { cancelled: false, hasNextPage: false, pageId: "page-2" },
  ];
  let dispatched: AnalyzeInboxPagePayload[] | null = null;
  const result = await orchestrateManagedScan(
    { version: 1, scanRunId: "run-1", connectionId: "connection-1" },
    async () => {
      calls.push("fetch");
      const step = steps.shift();
      assert.ok(step);
      return step;
    },
    async (pages) => {
      dispatched = pages;
      calls.push(`analyze-batch:${pages.map((p) => p.pageId).join(",")}`);
      return { cancelled: false };
    },
  );
  // Both fetches happen before the single fan-out batch (not interleaved per page).
  assert.deepEqual(calls, ["fetch", "fetch", "analyze-batch:page-1,page-2"]);
  assert.deepEqual(dispatched, [
    { version: 1, scanRunId: "run-1", pageId: "page-1" },
    { version: 1, scanRunId: "run-1", pageId: "page-2" },
  ]);
  assert.deepEqual(result, { cancelled: false, pagesProcessed: 2 });
});

test("cancellation during fetch stops before dispatching any analysis", async () => {
  let analyzed = false;
  const result = await orchestrateManagedScan(
    { version: 1, scanRunId: "run-1", connectionId: "connection-1" },
    async () => ({ cancelled: true, hasNextPage: false, pageId: null }),
    async () => {
      analyzed = true;
      return { cancelled: false };
    },
  );
  assert.equal(analyzed, false);
  assert.deepEqual(result, { cancelled: true, pagesProcessed: 0 });
});

test("cancellation reported by the analysis batch surfaces as cancelled", async () => {
  const steps = [{ cancelled: false, hasNextPage: false, pageId: "page-1" }];
  const result = await orchestrateManagedScan(
    { version: 1, scanRunId: "run-1", connectionId: "connection-1" },
    async () => {
      const step = steps.shift();
      assert.ok(step);
      return step;
    },
    async () => ({ cancelled: true }),
  );
  assert.deepEqual(result, { cancelled: true, pagesProcessed: 1 });
});

test("a run with no pages does not dispatch a batch", async () => {
  let analyzed = false;
  const result = await orchestrateManagedScan(
    { version: 1, scanRunId: "run-1", connectionId: "connection-1" },
    async () => ({ cancelled: false, hasNextPage: false, pageId: null }),
    async () => {
      analyzed = true;
      return { cancelled: false };
    },
  );
  assert.equal(analyzed, false);
  assert.deepEqual(result, { cancelled: false, pagesProcessed: 0 });
});

test("batch items carry a per-page idempotency key and a per-run concurrency key", () => {
  const pages: AnalyzeInboxPagePayload[] = [
    { version: 1, scanRunId: "run-1", pageId: "page-1" },
    { version: 1, scanRunId: "run-1", pageId: "page-2" },
  ];
  const items = pageAnalysisBatchItems(pages);
  assert.equal(items.length, 2);
  for (const [i, item] of items.entries()) {
    const page = pages[i];
    assert.ok(page);
    assert.deepEqual(item.payload, page);
    assert.equal(item.options.idempotencyKey, pageAnalysisIdempotencyKey("run-1", page.pageId));
    // All pages of a run share one concurrency key, so the per-run budget bounds their parallelism.
    assert.equal(item.options.concurrencyKey, pageAnalysisConcurrencyKey("run-1"));
  }
  // Distinct pages, distinct idempotency keys; identical concurrency key.
  assert.notEqual(items[0]!.options.idempotencyKey, items[1]!.options.idempotencyKey);
  assert.equal(items[0]!.options.concurrencyKey, items[1]!.options.concurrencyKey);
});
