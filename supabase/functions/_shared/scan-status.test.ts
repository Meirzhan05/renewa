import {
  aggregateRunStatus,
  classifyScanRun,
  DEFAULT_SCAN_COMPLETION_TIMEOUT_MS,
  scanCompletionTimeoutMs,
} from "./scan-status.ts";

function assertEquals<T>(actual: T, expected: T, message?: string): void {
  if (actual !== expected) {
    throw new Error(
      message ?? `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

const NOW = Date.parse("2026-08-29T12:00:00.000Z");
const TIMEOUT = 5 * 60_000;
const isoAgo = (ms: number) => new Date(NOW - ms).toISOString();

// The bug this fixes: a run handed to the worker but not yet finalized must NOT read as completed,
// or the app stops polling and shows a false "nothing to review".
Deno.test("handed-off run with a fresh unclaimed worker job is active, not completed", () => {
  const c = classifyScanRun(
    { status: "running", started_at: isoAgo(2_000) },
    { status: "pending", created_at: isoAgo(2_000) },
    NOW,
    TIMEOUT,
  );
  assertEquals(c, "active");
  assertEquals(aggregateRunStatus([c]), "running");
});

Deno.test("worker-finalized run (stage review_ready) is completed", () => {
  const c = classifyScanRun(
    { status: "completed", started_at: isoAgo(60_000) },
    { status: "completed", created_at: isoAgo(60_000) },
    NOW,
    TIMEOUT,
  );
  assertEquals(c, "completed");
  assertEquals(aggregateRunStatus([c]), "completed");
});

Deno.test("worker finished with no proposals still completes (true-empty preserved)", () => {
  // The worker sets status='completed' even when it surfaces nothing; that is a real completion.
  const c = classifyScanRun(
    { status: "completed", started_at: isoAgo(60_000) },
    { status: "completed", created_at: isoAgo(60_000) },
    NOW,
    TIMEOUT,
  );
  assertEquals(c, "completed");
});

Deno.test("unclaimed worker job past the timeout fails (worker down)", () => {
  const c = classifyScanRun(
    { status: "running", started_at: isoAgo(10 * 60_000) },
    { status: "pending", created_at: isoAgo(10 * 60_000) },
    NOW,
    TIMEOUT,
  );
  assertEquals(c, "failed");
  assertEquals(aggregateRunStatus([c]), "failed");
});

Deno.test("claimed (running) worker job past the timeout stays active (slow-but-alive)", () => {
  const c = classifyScanRun(
    { status: "running", started_at: isoAgo(10 * 60_000) },
    { status: "running", created_at: isoAgo(10 * 60_000) },
    NOW,
    TIMEOUT,
  );
  assertEquals(c, "active");
});

Deno.test("missing worker job past the timeout fails via the run start fallback", () => {
  const c = classifyScanRun(
    { status: "running", started_at: isoAgo(10 * 60_000) },
    undefined,
    NOW,
    TIMEOUT,
  );
  assertEquals(c, "failed");
});

Deno.test("a worker job that itself failed classifies the run failed", () => {
  const c = classifyScanRun(
    { status: "running", started_at: isoAgo(30_000) },
    { status: "failed", created_at: isoAgo(30_000) },
    NOW,
    TIMEOUT,
  );
  assertEquals(c, "failed");
});

Deno.test("aggregate: any active run keeps the whole scan running", () => {
  assertEquals(aggregateRunStatus(["completed", "active"]), "running");
});

Deno.test("aggregate: all terminal with a failure is partial", () => {
  assertEquals(aggregateRunStatus(["completed", "failed"]), "partial");
});

Deno.test("aggregate: all failed is failed, not partial", () => {
  assertEquals(aggregateRunStatus(["failed", "failed"]), "failed");
});

Deno.test("aggregate: empty set is completed (nothing to wait on)", () => {
  assertEquals(aggregateRunStatus([]), "completed");
});

Deno.test("timeout env parsing falls back on missing/invalid values", () => {
  assertEquals(scanCompletionTimeoutMs("120000"), 120000);
  assertEquals(scanCompletionTimeoutMs(undefined), DEFAULT_SCAN_COMPLETION_TIMEOUT_MS);
  assertEquals(scanCompletionTimeoutMs(""), DEFAULT_SCAN_COMPLETION_TIMEOUT_MS);
  assertEquals(scanCompletionTimeoutMs("nonsense"), DEFAULT_SCAN_COMPLETION_TIMEOUT_MS);
  assertEquals(scanCompletionTimeoutMs("-5"), DEFAULT_SCAN_COMPLETION_TIMEOUT_MS);
});
