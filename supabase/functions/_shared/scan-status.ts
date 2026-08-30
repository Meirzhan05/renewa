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
): RunClassification {
  if (run.status === "cancelled") return "cancelled";
  // A persisted failure is terminal. It may have residual queued execution records from an older
  // delivery, but those records must not revive a run the coordinator has already failed.
  if (run.status === "failed") return "failed";
  if (edgeJobs.some((job) => job.status === "queued" || job.status === "running")) {
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
