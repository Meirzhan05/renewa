import assert from "node:assert/strict";
import { test } from "node:test";
import {
  isAnalyzeInboxPagePayload,
  isScanInboxRunPayload,
  MANAGED_INBOX_TASK_VERSION,
  pageAnalysisIdempotencyKey,
  scanRunIdempotencyKey,
} from "../src/managed/contracts.ts";
import { loadManagedRuntimeConfig } from "../src/managed/config.ts";
import { TriggerManagedInboxRuntime, type TriggerTask } from "../src/managed/trigger-runtime.ts";

test("managed task contracts accept opaque identifiers only", () => {
  assert.equal(isScanInboxRunPayload({
    version: MANAGED_INBOX_TASK_VERSION,
    scanRunId: "run-1",
    connectionId: "connection-1",
  }), true);
  assert.equal(isAnalyzeInboxPagePayload({
    version: MANAGED_INBOX_TASK_VERSION,
    scanRunId: "run-1",
    pageId: "page-1",
    executionId: "execution-1",
    dispatchToken: "token-1",
  }), true);
  assert.equal(isAnalyzeInboxPagePayload({
    version: MANAGED_INBOX_TASK_VERSION,
    scanRunId: "run-1",
    pageId: "page-1",
    executionId: "execution-1",
    dispatchToken: "token-1",
    accessToken: "must-not-be-a-contract-field",
  }), false, "credential data must never enter a managed task contract");
  assert.equal(isAnalyzeInboxPagePayload({ version: 1, scanRunId: "run-1" }), false);
});

test("managed runtime config validates bounded concurrency", () => {
  const config = loadManagedRuntimeConfig({
    TRIGGER_SECRET_KEY: "tr_dev_test",
    INBOX_AGENT_GLOBAL_CONCURRENCY: "24",
    INBOX_AGENT_GOOGLE_CONCURRENCY: "8",
    INBOX_AGENT_MICROSOFT_CONCURRENCY: "7",
    INBOX_AGENT_PER_USER_CONCURRENCY: "1",
  });
  assert.equal(config.globalConcurrency, 24);
  assert.throws(
    () => loadManagedRuntimeConfig({ TRIGGER_SECRET_KEY: "tr_dev_test", INBOX_AGENT_GLOBAL_CONCURRENCY: "0" }),
    /positive integer/,
  );
});

test("Trigger runtime applies one idempotency key per durable dispatch attempt", async () => {
  const calls: Array<{ id: string; payload: Record<string, unknown>; options: Record<string, string> }> = [];
  const trigger: TriggerTask = async (id, payload, options) => {
    calls.push({ id, payload, options });
    return { id: "run_trigger_1" };
  };
  const runtime = new TriggerManagedInboxRuntime(trigger);
  await runtime.triggerScanRun({ version: 2, scanRunId: "scan-1", connectionId: "conn-1" });
  await runtime.triggerPageAnalysis({ version: 2, scanRunId: "scan-1", pageId: "page-1", executionId: "execution-1", dispatchToken: "token-1" }, "user-1", "google");
  assert.deepEqual(calls.map((call) => call.id), ["scan-inbox-run", "analyze-inbox-page"]);
  const [scanCall, pageCall] = calls;
  assert.ok(scanCall);
  assert.ok(pageCall);
  assert.equal(scanCall.options.idempotencyKey, scanRunIdempotencyKey("scan-1"));
  assert.equal(pageCall.options.idempotencyKey, pageAnalysisIdempotencyKey("execution-1", "token-1"));
  assert.equal(pageCall.options.concurrencyKey, undefined);
  assert.deepEqual(Object.keys(pageCall.payload).sort(), ["dispatchToken", "executionId", "pageId", "scanRunId", "version"]);
});
