// Pure scan-status derivation shared by the email-scan edge function and its tests.
//
// The iOS app learns "is the scan done" solely from the aggregate status computed here, so it must
// track the WORKER's real progress on the run -- not the edge's enqueue queue (`email_scan_jobs`),
// which is marked completed the instant the mailbox window is handed to the worker. The run row
// (`email_scan_runs`) is the single source of truth both writers already own: the edge marks it
// `failed` on a fetch error, and the worker marks it `completed` when it finishes and bridges
// candidates. The worker queue (`scan_jobs`) is consulted only for liveness: a `running` (claimed)
// job means a worker is alive; a `pending` (unclaimed) or missing job past a timeout means no
// worker is draining the queue, so the scan must fail rather than look emptily "completed".

export type RunClassification = "active" | "completed" | "failed" | "cancelled";

export type ScanRunState = {
  /** `email_scan_runs.status` (worker-finalized: `completed`; edge on fetch error: `failed`). */
  status: string | null;
  /** Fallback timeout anchor when no worker job row exists. */
  started_at?: string | null;
};

export type WorkerJobState = {
  /** `scan_jobs.status`: `pending` | `running` | `completed` | `failed`. */
  status: string | null;
  /** Enqueue time -- the primary anchor for the worker-down timeout. */
  created_at?: string | null;
};

export type EdgeJobState = {
  /** `email_scan_jobs.status`: `queued` | `running` | `completed` | `failed`. */
  status: string | null;
};

/** Durable managed-runtime state mirrored in Supabase; it is safe for status derivation only. */
export type ManagedExecutionState = {
  state: string | null;
};

export const DEFAULT_SCAN_COMPLETION_TIMEOUT_MS = 5 * 60_000;

/** Parse `SCAN_COMPLETION_TIMEOUT_MS` (env string) into a positive ms value, else the default. */
export function scanCompletionTimeoutMs(raw: string | null | undefined): number {
  const parsed = Number(raw);
  return Number.isFinite(parsed) && parsed > 0
    ? parsed
    : DEFAULT_SCAN_COMPLETION_TIMEOUT_MS;
}

// Grace before a managed scan whose runtime task never materialized (dispatched `scan-inbox-run`
// EXPIRED with no worker connected) is failed. It must be at least as long as the dispatched run's
// TTL (10m) so a validly-queued runtime run is not failed prematurely.
export const DEFAULT_SCAN_DISPATCH_GRACE_MS = 12 * 60_000;

/** Parse `SCAN_DISPATCH_GRACE_MS` (env string) into a positive ms value, else the default. */
export function scanDispatchGraceMs(raw: string | null | undefined): number {
  const parsed = Number(raw);
  return Number.isFinite(parsed) && parsed > 0
    ? parsed
    : DEFAULT_SCAN_DISPATCH_GRACE_MS;
}

/**
 * Classify a single run from the worker-owned run lifecycle plus its worker-queue job.
 *
 * A run finalized by the worker (`completed`) or failed by the edge (`failed`) is terminal. An
 * unfinalized run is corroborated with its worker job: a claimed (`running`) job is alive and stays
 * `active` no matter how long it takes; an unclaimed (`pending`) or missing job that has sat past
 * `timeoutMs` (measured from enqueue, falling back to the run's start) is treated as `failed`
 * because nothing is draining the queue.
 */
export function classifyScanRun(
  run: ScanRunState,
  workerJob: WorkerJobState | undefined,
  nowMs: number,
  timeoutMs: number,
): RunClassification {
  const runStatus = run.status ?? "";
  if (runStatus === "completed") return "completed";
  if (runStatus === "failed") return "failed";
  if (runStatus === "cancelled") return "cancelled";

  const jobStatus = workerJob?.status ?? null;
  if (jobStatus === "completed") return "completed";
  if (jobStatus === "failed") return "failed";
  if (jobStatus === "running") return "active"; // claimed and alive -> never time out

  // `pending` (unclaimed) or no worker job row: apply the worker-down timeout.
  const anchor = timestampMs(workerJob?.created_at) ?? timestampMs(run.started_at);
  if (anchor !== null && nowMs - anchor > timeoutMs) return "failed";
  return "active";
}

/**
 * Classify a paginated run. A run row is shared by every mailbox page, so it must never win over
 * active page work: an earlier worker page can have written a stale `completed` value while later
 * jobs remain pending. Worker jobs are classified independently so the timeout still applies to an
 * unclaimed page without falsely timing out a page a worker has claimed.
 */
export function classifyPaginatedScanRun(
  run: ScanRunState,
  edgeJobs: EdgeJobState[],
  workerJobs: WorkerJobState[],
  nowMs: number,
  timeoutMs: number,
  managedExecutions: ManagedExecutionState[] = [],
  dispatchGraceMs: number = timeoutMs,
): RunClassification {
  if (run.status === "cancelled") return "cancelled";
  // A persisted failure is terminal. It may have residual queued execution records from an older
  // delivery, but those records must not revive a run the coordinator has already failed.
  if (run.status === "failed") return "failed";
  if (edgeJobs.some((job) => job.status === "queued" || job.status === "running")) {
    // A queued/running edge page is normally active work. But a managed scan whose runtime task
    // never materialized -- the dispatched `scan-inbox-run` EXPIRED because no worker was connected
    // -- leaves the page window queued with NOTHING downstream: no worker job and no execution
    // record. If that persists past the dispatch-grace window the run can never progress, so fail it
    // rather than report it active forever. Any real work (a worker page or a durable execution
    // record) exempts the run, so a multi-page or capacity-waiting scan is never affected.
    if (
      workerJobs.length === 0 &&
      managedExecutions.length === 0 &&
      isPastTimeout(run.started_at, nowMs, dispatchGraceMs)
    ) {
      return "failed";
    }
    return "active";
  }
  // A managed task waiting for Trigger capacity is healthy work. Unlike a legacy pending
  // scan_jobs row, it has a durable execution record and must not be failed by a wall-clock UI
  // timeout while the runtime owns its retry and queue lifecycle.
  if (managedExecutions.some((execution) =>
    ["queued", "leased", "running", "retryable"].includes(execution.state ?? "")
  )) {
    return "active";
  }

  const workerClassifications = workerJobs.map((job) =>
    classifyScanRun({ status: "running", started_at: run.started_at }, job, nowMs, timeoutMs)
  );
  if (workerClassifications.some((classification) => classification === "active")) {
    return "active";
  }
  if (
    run.status === "failed" ||
    edgeJobs.some((job) => job.status === "failed") ||
    workerClassifications.some((classification) => classification === "failed") ||
    managedExecutions.some((execution) => execution.state === "failed")
  ) {
    return "failed";
  }

  // With no worker row, retain the prior missing-worker timeout behavior rather than treating an
  // enqueue-only run as successful. Otherwise every worker page has terminally completed.
  if (workerJobs.length === 0) {
    return classifyScanRun(run, undefined, nowMs, timeoutMs);
  }
  return "completed";
}

/**
 * Reduce per-run classifications into the app-visible aggregate status. Mirrors the prior
 * failed/partial/completed/running semantics, keyed off the full edge and worker page queues.
 * Returns `completed` for an empty set (no runs to wait on).
 */
export function aggregateRunStatus(classifications: RunClassification[]): string {
  if (classifications.length === 0) return "completed";
  const failed = classifications.filter((c) => c === "failed").length;
  const active = classifications.filter((c) => c === "active").length;
  const cancelled = classifications.filter((c) => c === "cancelled").length;
  if (failed === classifications.length) return "failed";
  if (cancelled === classifications.length) return "cancelled";
  if (active === 0) return failed > 0 ? "partial" : "completed";
  return "running";
}

function timestampMs(value: string | null | undefined): number | null {
  if (!value) return null;
  const ms = Date.parse(value);
  return Number.isNaN(ms) ? null : ms;
}

/** True when `anchor` is a parseable timestamp older than `timeoutMs` before `nowMs`. */
function isPastTimeout(
  anchor: string | null | undefined,
  nowMs: number,
  timeoutMs: number,
): boolean {
  const ms = timestampMs(anchor);
  return ms !== null && nowMs - ms > timeoutMs;
}

// --- Cumulative progress across a run's mailbox pages ---------------------------------------------
// Progress (messages checked / likely-billing / detected) is derived from the per-page ledger by the
// `email_scan_batch_progress` SQL function, which SUMs each page's count for a run. That aggregation
// is intentionally in SQL (payloads never transfer; a retried page replaces its row rather than adding
// one, so it cannot double-count). These helpers only shape the aggregate's rows for the response.

/** One row of `email_scan_batch_progress` (bigints arrive as number or numeric-string). */
export type RunProgressRow = {
  scan_run_id: string;
  messages_scanned: number | string | null;
  likely_billing: number | string | null;
  detected: number | string | null;
};

export type RunProgress = { scanned: number; likelyBilling: number; detected: number };

export const EMPTY_RUN_PROGRESS: RunProgress = { scanned: 0, likelyBilling: 0, detected: 0 };

/** Index the aggregate rows by run id, coercing bigint-as-string to number. */
export function indexRunProgress(rows: RunProgressRow[]): Map<string, RunProgress> {
  const byRun = new Map<string, RunProgress>();
  for (const row of rows) {
    byRun.set(String(row.scan_run_id), {
      scanned: Number(row.messages_scanned ?? 0),
      likelyBilling: Number(row.likely_billing ?? 0),
      detected: Number(row.detected ?? 0),
    });
  }
  return byRun;
}

/** Sum per-run progress into the batch-wide totals the app shows for the whole scan. */
export function totalRunProgress(byRun: Map<string, RunProgress>): RunProgress {
  return [...byRun.values()].reduce(
    (acc, page) => ({
      scanned: acc.scanned + page.scanned,
      likelyBilling: acc.likelyBilling + page.likelyBilling,
      detected: acc.detected + page.detected,
    }),
    { ...EMPTY_RUN_PROGRESS },
  );
}
