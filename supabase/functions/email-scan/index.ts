import { handleOptions, json } from "../_shared/http.ts";
import {
  adminClient,
  authenticatedUser,
  mustEnv,
} from "../_shared/supabase.ts";
import { decryptJSON, encryptJSON, sha256 } from "../_shared/crypto.ts";
import { Provider, refreshTokens, StoredTokens } from "../_shared/oauth.ts";
import {
  managedInboxEnabled,
  managedPageIdempotencyKey,
  managedRunConcurrencyKey,
  managedRunIdempotencyKey,
  managedRunPayload,
  triggerManagedInboxTask,
} from "../_shared/managed-inbox-runtime.ts";
import {
  BillingCycle,
  BillingEvent,
  brandIDForMerchant,
  candidateConfirmationIssues,
  canonicalMerchantKey,
  classifyCandidateAction,
  MailMessage,
  MailMetadata,
  reconcileMerchantLifecycle,
  redactEmailAddress,
  reviewTransitionResult,
  SubscriptionCategory,
  tintForCategory,
} from "../_shared/email-discovery.ts";
import { buildLearningSummary } from "../_shared/inbox-scan-dashboard.ts";
import {
  aggregateRunStatus,
  classifyPaginatedScanRun,
  EMPTY_RUN_PROGRESS,
  indexRunProgress,
  type RunClassification,
  type RunProgressRow,
  scanCompletionTimeoutMs,
  totalRunProgress,
} from "../_shared/scan-status.ts";
import {
  cursorRecoveryLookbackDays,
  gmailHistoricalQuery,
  initialMailboxLookbackDays,
  microsoftHistoricalFilter,
} from "../_shared/email-scan-window.ts";
import {
  renewDueInboxMonitoring,
  stopInboxMonitoring,
} from "../_shared/inbox-monitoring.ts";
import {
  derivePriorUpserts,
  type MerchantReviewPrior,
  overlayPriorsOntoEvent,
  type ReviewedFieldValues,
} from "../_shared/merchant-review-priors.ts";

type AdminClient = ReturnType<typeof adminClient>;

type ConnectionRow = {
  id: string;
  user_id: string;
  provider: Provider;
  email: string | null;
  encrypted_tokens: string;
  last_scanned_at: string | null;
  created_at: string;
};

type SyncState = {
  connection_id: string;
  cursor_kind: "gmail_history" | "microsoft_delta";
  cursor_value: string;
  last_successful_at: string;
  last_error: string | null;
};

type ProviderBatch = {
  metadata: MailMetadata[];
  cursorKind: SyncState["cursor_kind"];
  cursorValue: string;
  continuation: string | null;
  fullMessage: (metadata: MailMetadata) => Promise<MailMessage>;
};

type ProcessedConnectionPage = {
  hasNextPage: boolean;
  managedPageID: string | null;
};

type ScanJob = {
  id: string;
  batch_id: string;
  scan_run_id: string;
  connection_id: string;
  attempts: number;
  page_number: number;
  provider_continuation: string | null;
};

type CandidateEdits = {
  merchant_name?: string;
  amount?: number;
  currency?: string;
  billing_cycle?: BillingCycle;
  renewal_date?: string;
  category?: SubscriptionCategory;
};

const maximumMessagesPerHistoricalPage = 100;
const maximumIncrementalMessages = 500;
// Cap the historical backfill so a large mailbox pages back far enough to reach older monthly
// billing receipts, without walking unboundedly. 30 pages x 100 = up to 3000 messages per initial
// scan (subsequent scans are incremental).
const maximumHistoricalPages = 30;
const extractionSchemaVersion = "billing-event-v1";

Deno.serve(async (request) => {
  const options = handleOptions(request);
  if (options) return options;
  if (request.method !== "POST") {
    return json({ message: "Method not allowed" }, 405);
  }

  try {
    const admin = adminClient();
    const body = await request.json().catch(() => ({})) as Record<
      string,
      unknown
    >;
    const action = typeof body.action === "string" ? body.action : "start";

    if (["managed_page_context", "managed_process_connection"].includes(action)) {
      if (request.headers.get("x-renewa-managed-agent-secret") !== mustEnv("MANAGED_AGENT_SHARED_SECRET")) {
        return json({ message: "Invalid managed agent secret" }, 401);
      }
      if (action === "managed_page_context") {
        return json(await managedPageContext(admin, body));
      }
      return json(await processManagedConnection(admin, body));
    }

    if (
      ["automatic", "continue", "reconcile", "renew_monitoring"].includes(
        action,
      )
    ) {
      if (
        request.headers.get("x-renewa-monitor-secret") !==
          mustEnv("INBOX_MONITOR_SECRET")
      ) {
        return json({ message: "Invalid monitor secret" }, 401);
      }
      if (action === "continue") {
        const userID = requiredString(body.user_id, "user_id");
        const batchID = requiredString(body.batch_id, "batch_id");
        scheduleUserJobs(admin, userID, batchID);
        return json({ status: "processing" }, 202);
      }
      if (action === "renew_monitoring") {
        return json(await renewDueInboxMonitoring(admin));
      }
      return json(await runAutomaticScans(admin, action === "automatic"));
    }

    const user = await authenticatedUser(request);

    switch (action) {
      case "start": {
        const started = await startScan(admin, user.id);
        const scanID = typeof started.scan_id === "string"
          ? started.scan_id
          : null;
        scheduleUserJobs(admin, user.id, scanID);
        return json(started, started.reused ? 200 : 202);
      }
      case "status": {
        const scanID = optionalString(body.scan_id);
        // Trigger.dev owns managed orchestration. Polling is read-only there; repeatedly
        // scheduling from each status refresh can create redundant retries when a task fails.
        if (!managedInboxEnabled()) scheduleUserJobs(admin, user.id, scanID);
        return json(await scanStatus(admin, user.id, scanID));
      }
      case "cancel":
        return json(await cancelScan(admin, user.id, requiredString(body.scan_id, "scan_id")));
      case "review":
        return json(await reviewCandidate(admin, user.id, body));
      case "suppress":
        return json(await suppressCandidate(admin, user.id, body));
      case "unsuppress":
        return json(
          await unsuppressMerchant(
            admin,
            user.id,
            requiredString(
              body.canonical_merchant_key,
              "canonical_merchant_key",
            ),
          ),
        );
      case "connections":
        return json({ connections: await connectionSummaries(admin, user.id) });
      case "disconnect":
        return json(
          await disconnectConnection(
            admin,
            user.id,
            requiredString(body.connection_id, "connection_id"),
          ),
        );
      case "clear_history":
        return json(await clearScanHistory(admin, user.id));
      default:
        return json({ message: "Unsupported email scan action" }, 400);
    }
  } catch (error) {
    const message = errorMessage(error, "Email discovery failed");
    const status =
      message === "Missing bearer token" || message === "Invalid session"
        ? 401
        : message.endsWith(" is required") || message.startsWith("Invalid ")
        ? 400
        : message === "Candidate not found" || message === "Connection not found"
        ? 404
        : message === "Connect Google or Microsoft before scanning."
        ? 409
        : 500;
    return json({ message }, status);
  }
});

async function startScan(
  admin: AdminClient,
  userID: string,
  connectionIDs?: string[],
): Promise<Record<string, unknown>> {
  const { data: activeJob, error: activeError } = await admin
    .from("email_scan_jobs")
    .select("batch_id")
    .eq("user_id", userID)
    .in("status", ["queued", "running"])
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (activeError) throw activeError;
  if (activeJob) {
    return {
      ...(await scanStatus(admin, userID, activeJob.batch_id)),
      reused: true,
    };
  }

  const { data: recentRun, error: recentError } = await admin
    .from("email_scan_runs")
    .select("batch_id,started_at")
    .eq("user_id", userID)
    .gte("started_at", new Date(Date.now() - 60_000).toISOString())
    .order("started_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (recentError) throw recentError;
  if (recentRun) {
    return {
      ...(await scanStatus(admin, userID, recentRun.batch_id)),
      reused: true,
      rate_limited: true,
    };
  }

  let connectionsQuery = admin
    .from("email_connections")
    .select(
      "id,user_id,provider,email,encrypted_tokens,last_scanned_at,created_at",
    )
    .eq("user_id", userID);
  if (connectionIDs?.length) {
    connectionsQuery = connectionsQuery.in("id", connectionIDs);
  }
  const { data: connections, error: connectionError } = await connectionsQuery
    .order("created_at", { ascending: true });
  if (connectionError) throw connectionError;
  if (!connections || connections.length === 0) {
    throw new Error("Connect Google or Microsoft before scanning.");
  }

  const batchID = crypto.randomUUID();
  const runRows = connections.map((connection) => ({
    user_id: userID,
    provider: connection.provider,
    status: "running",
    stage: "queued",
    batch_id: batchID,
    error_message: null,
  }));
  const { data: runs, error: runError } = await admin
    .from("email_scan_runs")
    .insert(runRows)
    .select("id,provider");
  if (runError || !runs) {
    throw runError ?? new Error("Could not create scan runs");
  }

  const jobs = connections.map((connection) => {
    const run = runs.find((candidate) =>
      candidate.provider === connection.provider
    );
    if (!run) throw new Error("Could not pair scan connection");
    return {
      user_id: userID,
      batch_id: batchID,
      scan_run_id: run.id,
      connection_id: connection.id,
      page_number: 1,
      provider_continuation: null,
      status: "queued",
      error_message: null,
    };
  });
  const { error: jobError } = await admin.from("email_scan_jobs").insert(jobs);
  if (jobError) throw jobError;

  return {
    scan_id: batchID,
    status: "queued",
    stage: "queued",
    connection_count: connections.length,
    lookback_days: initialMailboxLookbackDays,
    scanned: 0,
    candidate_messages: 0,
    detected: 0,
    pending_count: 0,
    candidates: [],
    suppressed_merchants: await merchantSuppressions(admin, userID),
    connections: await connectionSummaries(admin, userID),
    errors: [],
    reused: false,
  };
}

async function cancelScan(
  admin: AdminClient,
  userID: string,
  batchID: string,
): Promise<Record<string, unknown>> {
  const { data: runs, error } = await admin.from("email_scan_runs")
    .select("id").eq("user_id", userID).eq("batch_id", batchID);
  if (error) throw error;
  if (!runs?.length) throw new Error("Invalid scan_id");
  for (const run of runs) {
    const { error: cancelError } = await admin.rpc("cancel_email_scan_run", {
      p_user_id: userID,
      p_run_id: run.id,
    });
    if (cancelError) throw cancelError;
    await finalizeScanRunIfDrained(admin, run.id);
  }
  return scanStatus(admin, userID, batchID);
}

async function runAutomaticScans(
  admin: AdminClient,
  renewMonitoring = false,
): Promise<Record<string, unknown>> {
  const eventWork = await runDueInboxMonitoringWork(admin);
  const monitoringRenewals = renewMonitoring
    ? await renewDueInboxMonitoring(admin)
    : null;
  const dueBefore = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const { data: connections, error } = await admin.from("email_connections")
    .select("id,user_id,created_at,last_automatic_scan_at")
    .eq("automatic_monitoring_enabled", true)
    .or(
      `last_automatic_scan_at.is.null,last_automatic_scan_at.lte.${dueBefore}`,
    )
    .limit(100);
  if (error) throw error;
  const groups = new Map<string, string[]>();
  for (const connection of connections ?? []) {
    const list = groups.get(String(connection.user_id)) ?? [];
    list.push(String(connection.id));
    groups.set(String(connection.user_id), list);
  }
  let queued = 0;
  for (const [userID, connectionIDs] of groups) {
    const started = await startScan(admin, userID, connectionIDs);
    if (!started.reused) queued += connectionIDs.length;
    scheduleUserJobs(
      admin,
      userID,
      typeof started.scan_id === "string" ? started.scan_id : null,
    );
    await admin.from("email_connections").update({
      last_automatic_scan_at: new Date().toISOString(),
    }).in("id", connectionIDs);
  }
  return {
    queued_connections: queued,
    monitored_users: groups.size,
    event_work: eventWork,
    monitoring_renewals: monitoringRenewals,
  };
}

async function runDueInboxMonitoringWork(
  admin: AdminClient,
): Promise<{ queuedConnections: number; deferredConnections: number }> {
  const now = new Date().toISOString();
  const { data: dueWork, error } = await admin
    .from("inbox_monitoring_due_work")
    .select("connection_id,user_id,attempts")
    .eq("event_pending", true)
    .lte("due_at", now)
    .is("claimed_at", null)
    .order("due_at", { ascending: true })
    .limit(100);
  if (error) throw error;

  let queuedConnections = 0;
  let deferredConnections = 0;
  for (const work of dueWork ?? []) {
    const claimedAt = new Date().toISOString();
    const { data: claimed, error: claimError } = await admin
      .from("inbox_monitoring_due_work")
      .update({ claimed_at: claimedAt, attempts: (work.attempts ?? 0) + 1 })
      .eq("connection_id", work.connection_id)
      .eq("event_pending", true)
      .is("claimed_at", null)
      .select("connection_id,user_id")
      .maybeSingle();
    if (claimError) throw claimError;
    if (!claimed) continue;

    try {
      const started = await startScan(admin, claimed.user_id, [
        claimed.connection_id,
      ]);
      if (started.reused) {
        deferredConnections += 1;
        await admin.from("inbox_monitoring_due_work").update({
          claimed_at: null,
          due_at: new Date(Date.now() + 2 * 60 * 1000).toISOString(),
          last_error: null,
        }).eq("connection_id", claimed.connection_id);
        continue;
      }
      queuedConnections += 1;
      scheduleUserJobs(
        admin,
        claimed.user_id,
        typeof started.scan_id === "string" ? started.scan_id : null,
      );
      await admin.from("inbox_monitoring_due_work").update({
        event_pending: false,
        claimed_at: null,
        completed_at: new Date().toISOString(),
        last_error: null,
      }).eq("connection_id", claimed.connection_id);
      await admin.from("inbox_monitoring_watches").update({
        health: "checking",
        last_error: null,
      })
        .eq("connection_id", claimed.connection_id);
    } catch (error) {
      const message = errorMessage(error, "Inbox monitoring scan failed").slice(
        0,
        280,
      );
      await admin.from("inbox_monitoring_due_work").update({
        claimed_at: null,
        due_at: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
        last_error: message,
      }).eq("connection_id", claimed.connection_id);
      await admin.from("inbox_monitoring_watches").update({
        health: "degraded",
        last_error: message,
      })
        .eq("connection_id", claimed.connection_id);
    }
  }
  return { queuedConnections, deferredConnections };
}

function scheduleUserJobs(
  admin: AdminClient,
  userID: string,
  batchID: string | null,
): void {
  const work = (managedInboxEnabled()
    ? processManagedUserJobs(admin, userID, batchID)
    : processUserJobs(admin, userID, batchID)).catch((error) => {
    console.error("email discovery worker failed", safeErrorMessage(error));
  });
  const runtime = (globalThis as unknown as {
    EdgeRuntime?: { waitUntil: (promise: Promise<unknown>) => void };
  }).EdgeRuntime;
  if (runtime) {
    runtime.waitUntil(work);
  } else {
    void work;
  }
}

async function processManagedUserJobs(
  admin: AdminClient,
  userID: string,
  batchID: string | null,
): Promise<void> {
  let query = admin.from("email_scan_jobs")
    .select("scan_run_id,connection_id")
    .eq("user_id", userID)
    .eq("status", "queued")
    .order("created_at", { ascending: true })
    .limit(10);
  if (batchID) query = query.eq("batch_id", batchID);
  const { data: jobs, error } = await query;
  if (error) throw error;
  for (const job of jobs ?? []) {
    await triggerManagedInboxTask(
      "scan-inbox-run",
      managedRunPayload(String(job.scan_run_id), String(job.connection_id)),
      {
        idempotencyKey: managedRunIdempotencyKey(String(job.scan_run_id), String(job.connection_id)),
        // A user may have several connections, but only one scan orchestrator may advance their
        // mailbox at a time. Waiting parent tasks checkpoint while their child analysis runs, so
        // this is fair across users without consuming an execution slot.
        concurrencyKey: managedRunConcurrencyKey(userID),
        queueName: "inbox-agent-runs",
        queueConcurrency: 20,
      },
    );
  }
}

async function managedPageContext(
  admin: AdminClient,
  body: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const runID = requiredString(body.scan_run_id, "scan_run_id");
  const jobID = requiredString(body.scan_job_id, "scan_job_id");
  const runtimeTaskID = requiredString(body.runtime_task_id, "runtime_task_id");
  const { data: job, error: jobError } = await admin.from("scan_jobs")
    .select("id,user_id,provider,scan_run_id,connection_id")
    .eq("id", jobID).eq("scan_run_id", runID).maybeSingle();
  if (jobError) throw jobError;
  if (!job) throw new Error("Managed scan page not found");
  const { data: execution, error: executionError } = await admin.from("inbox_agent_executions")
    .select("id")
    .eq("scan_job_id", jobID).eq("scan_run_id", runID).maybeSingle();
  if (executionError) throw executionError;
  if (!execution) throw new Error("Managed scan execution not found");
  const { data: claimed, error: claimError } = await admin.rpc("claim_inbox_agent_execution", {
    p_execution_id: execution.id,
    p_runtime_task_id: runtimeTaskID,
  });
  if (claimError) throw claimError;
  if (claimed !== true) return { cancelled: true };

  const { data: connection, error: connectionError } = await admin.from("email_connections")
    .select("id,provider,encrypted_tokens")
    .eq("id", job.connection_id).eq("user_id", job.user_id).maybeSingle();
  if (connectionError) throw connectionError;
  if (!connection) throw new Error("Connection was removed.");
  let tokens = await decryptJSON<StoredTokens>(connection.encrypted_tokens);
  const refreshed = await refreshTokens(connection.provider as Provider, tokens);
  if (refreshed.access_token !== tokens.access_token) {
    tokens = refreshed;
    const { error } = await admin.from("email_connections").update({
      encrypted_tokens: await encryptJSON(tokens),
      token_expires_at: new Date(tokens.expires_at * 1_000).toISOString(),
    }).eq("id", connection.id);
    if (error) throw error;
  }
  return { execution_id: execution.id, access_token: tokens.access_token };
}

async function processManagedConnection(
  admin: AdminClient,
  body: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const runID = requiredString(body.scan_run_id, "scan_run_id");
  const connectionID = requiredString(body.connection_id, "connection_id");
  const { data: run, error: runError } = await admin.from("email_scan_runs")
    .select("id,user_id,cancel_requested_at")
    .eq("id", runID).maybeSingle();
  if (runError) throw runError;
  if (!run) throw new Error("Managed scan run not found");
  if (run.cancel_requested_at) return { cancelled: true, has_next_page: false };
  const { data: job, error: jobError } = await admin.from("email_scan_jobs")
    .select("id,attempts,page_number,provider_continuation,batch_id")
    .eq("scan_run_id", runID).eq("connection_id", connectionID).eq("status", "queued")
    .order("created_at", { ascending: true }).limit(1).maybeSingle();
  if (jobError) throw jobError;
  if (!job) return { has_next_page: false };
  const { data: claimed, error: claimError } = await admin.from("email_scan_jobs")
    .update({ status: "running", attempts: job.attempts + 1, started_at: new Date().toISOString(), error_message: null })
    .eq("id", job.id).eq("status", "queued").select("id").maybeSingle();
  if (claimError) throw claimError;
  if (!claimed) return { has_next_page: true };
  try {
    const processed = await processConnectionJob(
      admin, run.user_id, runID, connectionID, job.page_number, job.provider_continuation, true,
    );
    await admin.from("email_scan_jobs").update({ status: "completed", completed_at: new Date().toISOString() })
      .eq("id", job.id);
    await finalizeScanRunIfDrained(admin, runID);
    await publishBatchNotificationState(admin, run.user_id, job.batch_id);
    return {
      has_next_page: processed.hasNextPage,
      page_id: processed.managedPageID,
    };
  } catch (error) {
    const message = safeErrorMessage(error);
    await admin.from("email_scan_jobs").update({
      status: "failed", error_message: message, completed_at: new Date().toISOString(),
    }).eq("id", job.id);
    await finalizeScanRunIfDrained(admin, runID);
    throw error;
  }
}

async function processUserJobs(
  admin: AdminClient,
  userID: string,
  batchID: string | null,
): Promise<void> {
  const staleBefore = new Date(Date.now() - 5 * 60_000).toISOString();
  let staleQuery = admin
    .from("email_scan_jobs")
    .update({
      status: "queued",
      available_at: new Date().toISOString(),
      error_message: "Worker resumed.",
    })
    .eq("user_id", userID)
    .eq("status", "running")
    .lt("started_at", staleBefore);
  if (batchID) staleQuery = staleQuery.eq("batch_id", batchID);
  await staleQuery;

  let query = admin
    .from("email_scan_jobs")
    .select(
      "id,batch_id,scan_run_id,connection_id,attempts,page_number,provider_continuation",
    )
    .eq("user_id", userID)
    .eq("status", "queued")
    .lte("available_at", new Date().toISOString())
    .order("created_at", { ascending: true })
    .limit(3);
  if (batchID) query = query.eq("batch_id", batchID);
  const { data: jobs, error } = await query;
  if (error) throw error;

  let needsFollowup = false;
  for (const job of (jobs ?? []) as ScanJob[]) {
    const { data: claimed, error: claimError } = await admin
      .from("email_scan_jobs")
      .update({
        status: "running",
        attempts: job.attempts + 1,
        started_at: new Date().toISOString(),
        error_message: null,
      })
      .eq("id", job.id)
      .eq("status", "queued")
      .select("id")
      .maybeSingle();
    if (claimError) throw claimError;
    if (!claimed) continue;

    try {
      const processed = await processConnectionJob(
        admin,
        userID,
        job.scan_run_id,
        job.connection_id,
        job.page_number,
        job.provider_continuation,
      );
      needsFollowup = needsFollowup || processed.hasNextPage;
      await admin.from("email_scan_jobs").update({
        status: "completed",
        completed_at: new Date().toISOString(),
      }).eq("id", job.id);
      await finalizeScanRunIfDrained(admin, job.scan_run_id);
      await admin.from("inbox_monitoring_watches").update({
        health: "active",
        last_error: null,
      }).eq("connection_id", job.connection_id).eq("health", "checking");
      await publishBatchNotificationState(admin, userID, job.batch_id);
    } catch (jobError) {
      const message = safeErrorMessage(jobError);
      const retryable = job.attempts + 1 < 3;
      await admin.from("email_connections").update({ last_error: message }).eq(
        "id",
        job.connection_id,
      ).eq("user_id", userID);
      await admin.from("inbox_monitoring_watches").update({
        health: /reconnect|access expired|invalid.*token|unauthori[sz]ed/i.test(
            message,
          )
          ? "reconnect_required"
          : "degraded",
        last_error: message.slice(0, 280),
      }).eq("connection_id", job.connection_id);
      await admin.from("email_scan_jobs").update({
        status: retryable ? "queued" : "failed",
        available_at: new Date(Date.now() + (job.attempts + 1) * 2_000)
          .toISOString(),
        completed_at: retryable ? null : new Date().toISOString(),
        error_message: message,
      }).eq("id", job.id);
      await admin.from("email_scan_runs").update({
        status: "running",
        stage: retryable ? "queued" : "reasoning",
        error_message: message,
        completed_at: null,
      }).eq("id", job.scan_run_id);
      await finalizeScanRunIfDrained(admin, job.scan_run_id);
      await publishBatchNotificationState(admin, userID, job.batch_id);
    }
  }
  if (needsFollowup && batchID) queueWorkerContinuation(userID, batchID);
}

async function finalizeScanRunIfDrained(
  admin: AdminClient,
  runID: string,
): Promise<void> {
  const { error } = await admin.rpc("finalize_email_scan_run_if_drained", {
    p_run_id: runID,
  });
  if (error) throw error;
}

async function publishBatchNotificationState(
  admin: AdminClient,
  userID: string,
  batchID: string,
): Promise<void> {
  try {
    const { error } = await admin.rpc("publish_inbox_scan_notification_state", {
      p_user_id: userID,
      p_batch_id: batchID,
    });
    if (error) throw error;
  } catch (error) {
    console.error(
      "Could not publish inbox scan notification state",
      safeErrorMessage(error),
    );
  }
}

async function processConnectionJob(
  admin: AdminClient,
  userID: string,
  runID: string,
  connectionID: string,
  pageNumber: number,
  providerContinuation: string | null,
  managedPage = false,
): Promise<ProcessedConnectionPage> {
  const { data: connection, error: connectionError } = await admin
    .from("email_connections")
    .select(
      "id,user_id,provider,email,encrypted_tokens,last_scanned_at,created_at",
    )
    .eq("id", connectionID)
    .eq("user_id", userID)
    .maybeSingle();
  if (connectionError) throw connectionError;
  if (!connection) throw new Error("Connection was removed.");

  const provider = connection.provider as Provider;
  await updateRun(admin, runID, { stage: "fetching" });
  let tokens = await decryptJSON<StoredTokens>(connection.encrypted_tokens);
  const refreshed = await refreshTokens(provider, tokens);
  if (refreshed.access_token !== tokens.access_token) {
    tokens = refreshed;
    const { error } = await admin.from("email_connections").update({
      encrypted_tokens: await encryptJSON(tokens),
      token_expires_at: new Date(tokens.expires_at * 1_000).toISOString(),
    }).eq("id", connection.id);
    if (error) throw error;
  }

  const { data: storedSync, error: syncError } = await admin
    .from("mail_sync_states")
    .select(
      "connection_id,cursor_kind,cursor_value,last_successful_at,last_error",
    )
    .eq("connection_id", connection.id)
    .maybeSingle();
  if (syncError) throw syncError;

  const providerBatch = provider === "google"
    ? await fetchGmailBatch(
      tokens.access_token,
      storedSync as SyncState | null,
      providerContinuation,
    )
    : await fetchMicrosoftBatch(
      tokens.access_token,
      storedSync as SyncState | null,
      providerContinuation,
    );

  await updateRun(admin, runID, {
    stage: "reasoning",
    messages_scanned: providerBatch.metadata.length,
    candidate_messages: providerBatch.metadata.length,
  });

  // Discovery no longer runs in the edge function. Hand the fetched window to the persistent agent
  // worker, which runs the autonomous funnel (Tier-1 triage -> Tier-2 agent -> propose), reconciles
  // against the user's tracked subscriptions / priors / suppressions, and writes candidates back
  // into this run's review queue before marking the run completed. The LLM alone decides what
  // surfaces -- there is no keyword prefilter or routing ladder here anymore.
  const { data: queuedScanJob, error: enqueueError } = await admin.from("scan_jobs").insert({
    user_id: userID,
    provider,
    // The managed path obtains this token JIT in its task. The legacy local worker keeps the
    // existing behavior behind the feature gate until it is retired after rollout.
    access_token: managedPage ? null : tokens.access_token,
    raw_messages: providerBatch.metadata,
    // Per-page ledger entry: the run's app-visible "messages checked" is SUM(message_count) over its
    // pages (see email_scan_batch_progress / change fix-managed-scan-page-counts), so this must be the
    // page's own window size, never the running total.
    message_count: providerBatch.metadata.length,
    scan_run_id: runID,
    batch_id: await scanRunBatchID(admin, runID),
    connection_id: connection.id,
  }).select("id").single();
  if (enqueueError) throw enqueueError;
  if (!queuedScanJob) throw new Error("Could not queue managed scan page");
  if (managedPage) {
    await admitManagedPageAnalysis(
      admin,
      userID,
      runID,
      String(queuedScanJob.id),
      connection.id,
    );
  }

  const now = new Date().toISOString();
  const { error: saveSyncError } = await admin.from("mail_sync_states").upsert({
    connection_id: connection.id,
    user_id: userID,
    cursor_kind: providerBatch.cursorKind,
    cursor_value: providerBatch.cursorValue,
    last_successful_at: now,
    last_error: null,
  }, { onConflict: "connection_id" });
  if (saveSyncError) throw saveSyncError;

  await admin.from("email_connections").update({
    last_scanned_at: now,
    last_error: null,
  }).eq("id", connection.id);

  // The run stays 'running' until the worker completes it via the candidate bridge. Page forward
  // while the provider reports more pages, so the backfill walks past recent mail to older billing
  // receipts (each page becomes its own worker scan job). The last page (no continuation) ends the
  // walk; the page cap bounds a very large mailbox. Returning true re-arms the drain via
  // queueWorkerContinuation.
  if (providerBatch.continuation !== null && pageNumber < maximumHistoricalPages) {
    const { error: nextPageError } = await admin.from("email_scan_jobs").insert({
      user_id: userID,
      batch_id: await scanRunBatchID(admin, runID),
      scan_run_id: runID,
      connection_id: connection.id,
      page_number: pageNumber + 1,
      provider_continuation: providerBatch.continuation,
      status: "queued",
      error_message: null,
    });
    if (nextPageError) throw nextPageError;
    return {
      hasNextPage: true,
      managedPageID: managedPage ? String(queuedScanJob.id) : null,
    };
  }
  return {
    hasNextPage: false,
    managedPageID: managedPage ? String(queuedScanJob.id) : null,
  };
}

async function admitManagedPageAnalysis(
  admin: AdminClient,
  userID: string,
  runID: string,
  pageID: string,
  connectionID: string,
): Promise<void> {
  const idempotencyKey = managedPageIdempotencyKey(runID, pageID);
  // Persist the admission record before triggering so an immediately-started task has a durable
  // claim target. A second call with the same key updates the runtime idempotently.
  const { error: admissionError } = await admin.rpc("admit_inbox_agent_execution", {
    p_user_id: userID,
    p_scan_run_id: runID,
    p_scan_job_id: pageID,
    p_connection_id: connectionID,
    p_task_kind: "page_analysis",
    p_idempotency_key: idempotencyKey,
    p_runtime_task_id: null,
  });
  if (admissionError) throw admissionError;
}

// --- Merchant lifecycle + candidate resolution -----------------------------------------------
// Discovery itself now runs in the persistent agent worker (worker/): the edge function enqueues a
// scan job and the worker's autonomous funnel decides what to surface. The helpers below are the
// shared lifecycle/suppression/resolution plumbing still used by scan status, review, and monitoring.

async function merchantLifecycle(
  admin: AdminClient,
  userID: string,
  merchantKey: string,
) {
  const { data, error } = await admin
    .from("detected_billing_events")
    .select(
      "id,event_type,amount,currency,billing_cycle,event_date,renewal_date,source_received_at",
    )
    .eq("user_id", userID)
    .eq("canonical_merchant_key", merchantKey)
    .order("source_received_at", { ascending: true });
  if (error) throw error;
  return reconcileMerchantLifecycle((data ?? []).map((event) => ({
    id: String(event.id),
    event_type: event.event_type,
    amount: numberOrNull(event.amount),
    currency: stringOrNull(event.currency),
    billing_cycle: event.billing_cycle as BillingCycle | null,
    event_date: stringOrNull(event.event_date),
    renewal_date: stringOrNull(event.renewal_date),
    source_received_at: String(event.source_received_at),
  })));
}

async function upsertEvidenceBundle(
  admin: AdminClient,
  userID: string,
  merchantKey: string,
  lifecycle: ReturnType<typeof reconcileMerchantLifecycle>,
  eventID: string,
  resolutionReason: string,
): Promise<string> {
  const { data: bundle, error } = await admin.from("merchant_evidence_bundles")
    .upsert({
      user_id: userID,
      canonical_merchant_key: merchantKey,
      lifecycle_state: lifecycle.state,
      resolution_reason: resolutionReason,
      supporting_event_id: lifecycle.supportingEventID,
    }, { onConflict: "user_id,canonical_merchant_key" })
    .select("id")
    .single();
  if (error || !bundle) {
    throw error ?? new Error("Could not save evidence bundle");
  }
  const { error: linkError } = await admin.from(
    "merchant_evidence_bundle_events",
  ).upsert({ bundle_id: bundle.id, event_id: eventID, user_id: userID }, {
    onConflict: "bundle_id,event_id",
  });
  if (linkError) throw linkError;
  return String(bundle.id);
}

async function merchantIsSuppressed(
  admin: AdminClient,
  userID: string,
  merchantKey: string,
): Promise<boolean> {
  const { data, error } = await admin
    .from("merchant_discovery_suppressions")
    .select("canonical_merchant_key")
    .eq("user_id", userID)
    .eq("canonical_merchant_key", merchantKey)
    .maybeSingle();
  if (error) throw error;
  return data !== null;
}

async function resolvePendingDiscoveryCandidates(
  admin: AdminClient,
  userID: string,
  merchantKey: string,
  reason: string,
): Promise<void> {
  const { error } = await admin.from("subscription_candidates")
    .update({
      review_status: "ignored",
      system_resolution_reason: reason,
      system_resolved_at: new Date().toISOString(),
      reviewed_at: new Date().toISOString(),
    })
    .eq("user_id", userID)
    .eq("canonical_merchant_key", merchantKey)
    .eq("review_status", "pending")
    .neq("event_type", "canceled");
  if (error) throw error;
}

async function resolveStaleCancellationCandidates(
  admin: AdminClient,
  userID: string,
  merchantKey: string,
  reason: string,
): Promise<void> {
  const { error } = await admin.from("subscription_candidates")
    .update({
      review_status: "ignored",
      system_resolution_reason: reason,
      system_resolved_at: new Date().toISOString(),
      reviewed_at: new Date().toISOString(),
    })
    .eq("user_id", userID)
    .eq("canonical_merchant_key", merchantKey)
    .eq("review_status", "pending")
    .eq("event_type", "canceled");
  if (error) throw error;
}

function lifecycleResolutionReason(state: "ended" | "uncertain"): string {
  return state === "ended"
    ? "Later ending evidence was found for this merchant."
    : "Current renewal evidence is unavailable for this merchant.";
}

async function scanStatus(
  admin: AdminClient,
  userID: string,
  requestedBatchID: string | null,
): Promise<Record<string, unknown>> {
  await reconcilePendingCandidates(admin, userID);
  let batchID = requestedBatchID;
  if (!batchID) {
    const { data: latest, error } = await admin
      .from("email_scan_runs")
      .select("batch_id")
      .eq("user_id", userID)
      .order("started_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (error) throw error;
    batchID = latest?.batch_id ?? null;
  }

  if (!batchID) {
    return {
      scan_id: null,
      status: "idle",
      stage: "idle",
      connection_count: 0,
      scanned: 0,
      candidate_messages: 0,
      detected: 0,
      pending_count: 0,
      candidates: [],
      runs: [],
      suppressed_merchants: await merchantSuppressions(admin, userID),
      connections: await connectionSummaries(admin, userID),
      learning_summary: await learningSummary(admin, userID),
      recent_activity: await recentActivity(admin, userID),
      withheld_ambiguities: 0,
      errors: [],
    };
  }

  const { data: runs, error: runsError } = await admin
    .from("email_scan_runs")
    .select(
      "id,provider,status,stage,started_at,messages_scanned,candidate_messages,events_detected,validation_failures,error_message",
    )
    .eq("user_id", userID)
    .eq("batch_id", batchID);
  if (runsError) throw runsError;
  if (!runs || runs.length === 0) throw new Error("Invalid scan_id");

  const { data: jobs, error: jobsError } = await admin
    .from("email_scan_jobs")
    .select("scan_run_id,status,error_message")
    .eq("user_id", userID)
    .eq("batch_id", batchID);
  if (jobsError) throw jobsError;

  // Worker queue (drained by the persistent agent worker), NOT the edge's `email_scan_jobs`. This
  // is the liveness signal for the aggregate status: a claimed ('running') job means a worker is
  // alive; a 'pending'/absent job past the timeout means nothing is draining the queue.
  const { data: workerJobs, error: workerJobsError } = await admin
    .from("scan_jobs")
    .select("scan_run_id,status,created_at,error")
    .eq("user_id", userID)
    .eq("batch_id", batchID);
  if (workerJobsError) throw workerJobsError;

  const { data: managedExecutions, error: managedExecutionsError } = await admin
    .from("inbox_agent_executions")
    .select("scan_run_id,state")
    .eq("user_id", userID)
    .in("scan_run_id", runs.map((run) => run.id));
  if (managedExecutionsError) throw managedExecutionsError;

  const { data: candidates, error: candidatesError } = await admin
    .from("subscription_candidates")
    .select(
      "id,matched_subscription_id,suggested_action,review_status,merchant_name,amount,currency,billing_cycle,renewal_date,category,event_type,confidence,evidence,validation_issues,created_at",
    )
    .eq("user_id", userID)
    .eq("review_status", "pending")
    .order("created_at", { ascending: false });
  if (candidatesError) throw candidatesError;

  // Cumulative per-run progress from the page ledger (scan_jobs), computed in SQL so message payloads
  // never transfer on a poll and a retried page cannot double-count. Replaces the per-page overwrite of
  // email_scan_runs.messages_scanned / candidate_messages / events_detected, which froze at one page.
  const { data: progressRows, error: progressError } = await admin.rpc(
    "email_scan_batch_progress",
    { p_user_id: userID, p_batch_id: batchID },
  );
  if (progressError) throw progressError;
  const progressByRun = indexRunProgress((progressRows ?? []) as RunProgressRow[]);
  const totalProgress = totalRunProgress(progressByRun);

  // Derive the app-visible status from the WORKER's real progress on each run (the run lifecycle it
  // finalizes + the worker queue's liveness), not the edge's `email_scan_jobs` queue -- which is
  // marked completed the moment the mailbox window is handed off, before the worker reasons at all.
  const workerTimeoutMessage = "Scan worker did not complete the job in time.";
  const workerFailedMessage = "Scan worker failed to complete the job.";
  const timeoutMs = scanCompletionTimeoutMs(
    Deno.env.get("SCAN_COMPLETION_TIMEOUT_MS"),
  );
  // The 5-minute-scale timeout compares enqueue time (a DB timestamp) against the edge clock;
  // NTP-synced sub-second skew is immaterial at this granularity, so no extra round trip for now().
  const nowMs = Date.now();
  const workerJobsByRun = new Map<string, Array<Record<string, unknown>>>();
  for (const job of workerJobs ?? []) {
    const runID = String(job.scan_run_id);
    workerJobsByRun.set(runID, [...(workerJobsByRun.get(runID) ?? []), job]);
  }
  const edgeJobsByRun = new Map<string, Array<Record<string, unknown>>>();
  for (const job of jobs ?? []) {
    const runID = String(job.scan_run_id);
    edgeJobsByRun.set(runID, [...(edgeJobsByRun.get(runID) ?? []), job]);
  }
  const managedExecutionsByRun = new Map<string, Array<Record<string, unknown>>>();
  for (const execution of managedExecutions ?? []) {
    const runID = String(execution.scan_run_id);
    managedExecutionsByRun.set(
      runID,
      [...(managedExecutionsByRun.get(runID) ?? []), execution],
    );
  }
  const classificationByRun = new Map<string, RunClassification>();
  // Runs the DB still reports as active but which are actually terminal-failed -- either the worker
  // is down (job never claimed, aged out) or the worker failed the job (it marks scan_jobs failed
  // but leaves email_scan_runs 'running'). Carry the right message per run so a real worker error is
  // not mislabeled as a timeout, and vice versa.
  const failureMessageByRun = new Map<string, string>();
  for (const run of runs) {
    const jobsForRun = workerJobsByRun.get(run.id) ?? [];
    const edgeJobsForRun = edgeJobsByRun.get(run.id) ?? [];
    const executionsForRun = managedExecutionsByRun.get(run.id) ?? [];
    const classification = classifyPaginatedScanRun(
      { status: run.status, started_at: run.started_at },
      edgeJobsForRun.map((job) => ({ status: String(job.status ?? "") })),
      jobsForRun.map((job) => ({
        status: String(job.status ?? ""),
        created_at: typeof job.created_at === "string" ? job.created_at : null,
      })),
      nowMs,
      timeoutMs,
      executionsForRun.map((execution) => ({ state: String(execution.state ?? "") })),
    );
    classificationByRun.set(run.id, classification);
    if (
      classification === "failed" &&
      run.status !== "failed" &&
      run.status !== "completed"
    ) {
      failureMessageByRun.set(
        run.id,
        jobsForRun.some((job) => job.status === "failed")
          ? workerFailedMessage
          : executionsForRun.some((execution) => execution.state === "failed")
          ? "A managed page analysis could not complete."
          : edgeJobsForRun.some((job) => job.status === "failed")
          ? "A mailbox page could not complete."
          : workerTimeoutMessage,
      );
    }
  }
  const aggregateStatus = aggregateRunStatus([...classificationByRun.values()]);
  const pendingCandidates = (candidates ?? []).filter((candidate) =>
    candidate.review_status === "pending"
  );

  // Best-effort write-through (design D4): persist the failure so the run stops reporting 'running'
  // forever and history/notifications stay consistent. The response returns the failed status
  // regardless of whether these writes succeed. Runs are per-connection (usually one), so a small
  // per-run loop is fine and lets each keep its own message.
  for (const [runID, message] of failureMessageByRun) {
    const { error: failWriteError } = await admin
      .from("email_scan_runs")
      .update({
        status: "failed",
        stage: "failed",
        error_message: message,
        completed_at: new Date().toISOString(),
      })
      .eq("id", runID);
    if (failWriteError) {
      console.error(
        "Could not persist scan run failure",
        safeErrorMessage(failWriteError),
      );
    }
  }

  return {
    scan_id: batchID,
    status: aggregateStatus,
    stage: aggregateStage(runs, aggregateStatus),
    connection_count: runs.length,
    scanned: totalProgress.scanned,
    candidate_messages: totalProgress.likelyBilling,
    detected: totalProgress.detected,
    validation_failures: sum(runs, "validation_failures"),
    withheld_ambiguities: sum(runs, "withheld_ambiguities"),
    pending_count: pendingCandidates.length,
    runs: runs.map((run) => {
      const job = (edgeJobsByRun.get(run.id) ?? []).find((item) =>
        typeof item.error_message === "string" && item.error_message.length > 0
      );
      const classification = classificationByRun.get(run.id) ?? "active";
      const failureMessage = failureMessageByRun.get(run.id);
      const progress = progressByRun.get(run.id) ?? EMPTY_RUN_PROGRESS;
      return {
        provider: run.provider,
        // Match the aggregate: active -> 'running', otherwise the terminal classification. The
        // edge's `email_scan_jobs` status is no longer used here (it completes at hand-off).
        status: classification === "active" ? "running" : classification,
        stage: failureMessage ? "failed" : run.stage,
        scanned: progress.scanned,
        candidate_messages: progress.likelyBilling,
        detected: progress.detected,
        error: failureMessage ?? run.error_message ?? job?.error_message ?? null,
      };
    }),
    candidates: (candidates ?? []).map((candidate) => ({
      ...candidate,
      evidence_events: [{
        event_type: candidate.event_type,
        merchant_name: candidate.merchant_name,
        received_at: candidate.created_at,
        evidence: candidate.evidence,
      }],
    })),
    suppressed_merchants: await merchantSuppressions(admin, userID),
    connections: await connectionSummaries(admin, userID),
    learning_summary: await learningSummary(admin, userID),
    recent_activity: await recentActivity(admin, userID),
    errors: uniqueStrings([
      ...runs.map((run) => run.error_message),
      ...(jobs ?? []).map((job) => job.error_message),
      ...failureMessageByRun.values(),
    ]),
  };
}

async function learningSummary(
  admin: AdminClient,
  userID: string,
): Promise<Record<string, unknown>> {
  const { data: bundles, error: bundlesError } = await admin
    .from("merchant_evidence_bundles")
    .select(
      "canonical_merchant_key,lifecycle_state,resolution_reason,updated_at",
    )
    .eq("user_id", userID)
    .order("updated_at", { ascending: false });
  if (bundlesError) throw bundlesError;

  const safeBundles = (bundles ?? []) as Array<{
    canonical_merchant_key: string;
    lifecycle_state: "current" | "ended" | "uncertain";
    resolution_reason: string;
    updated_at: string;
  }>;
  const keys = safeBundles.map((bundle) => bundle.canonical_merchant_key);
  if (keys.length === 0) {
    return { ended_count: 0, uncertain_count: 0, items: [] };
  }

  const { data: events, error: eventsError } = await admin
    .from("detected_billing_events")
    .select(
      "canonical_merchant_key,merchant_name,event_type,source_received_at,evidence",
    )
    .eq("user_id", userID)
    .in("canonical_merchant_key", keys)
    .order("source_received_at", { ascending: false });
  if (eventsError) throw eventsError;

  return buildLearningSummary(
    safeBundles,
    (events ?? []) as Array<{
      canonical_merchant_key: string | null;
      merchant_name: string;
      event_type: string;
      source_received_at: string;
      evidence: string | null;
    }>,
  );
}

async function recentActivity(
  admin: AdminClient,
  userID: string,
): Promise<Array<Record<string, unknown>>> {
  const { data: outcomes, error: outcomeError } = await admin
    .from("subscription_candidate_review_outcomes")
    .select("id,candidate_id,outcome,proposed_fields,applied_fields,created_at")
    .eq("user_id", userID)
    .order("created_at", { ascending: false })
    .limit(6);
  if (outcomeError) throw outcomeError;
  if (!outcomes || outcomes.length === 0) return [];

  const candidateIDs = outcomes.map((outcome) => String(outcome.candidate_id));
  const { data: candidates, error: candidateError } = await admin
    .from("subscription_candidates")
    .select("id,merchant_name,amount,currency,event_type")
    .eq("user_id", userID)
    .in("id", candidateIDs);
  if (candidateError) throw candidateError;

  const candidateByID = new Map(
    (candidates ?? []).map((candidate) => [String(candidate.id), candidate]),
  );
  return outcomes.flatMap((outcome) => {
    const candidate = candidateByID.get(String(outcome.candidate_id));
    const applied = isRecord(outcome.applied_fields) ? outcome.applied_fields : {};
    const proposed = isRecord(outcome.proposed_fields) ? outcome.proposed_fields : {};
    const merchantName = candidate?.merchant_name ??
      stringOrNull(applied.merchant_name) ??
      stringOrNull(proposed.merchant_name);
    if (!merchantName) return [];
    return [{
      id: outcome.id,
      merchant_name: merchantName,
      outcome: outcome.outcome,
      event_type: candidate?.event_type ?? null,
      amount: candidate?.amount ?? numberOrNull(applied.amount) ?? numberOrNull(proposed.amount),
      currency: candidate?.currency ?? stringOrNull(applied.currency) ?? stringOrNull(proposed.currency),
      created_at: outcome.created_at,
    }];
  });
}

async function merchantSuppressions(
  admin: AdminClient,
  userID: string,
): Promise<Array<Record<string, unknown>>> {
  const { data, error } = await admin
    .from("merchant_discovery_suppressions")
    .select("canonical_merchant_key,created_at")
    .eq("user_id", userID)
    .order("created_at", { ascending: false });
  if (error) throw error;
  return (data ?? []).map((suppression) => ({
    canonical_merchant_key: suppression.canonical_merchant_key,
    created_at: suppression.created_at,
  }));
}

async function reconcilePendingCandidates(
  admin: AdminClient,
  userID: string,
): Promise<void> {
  const { data: candidates, error } = await admin
    .from("subscription_candidates")
    .select("id,canonical_merchant_key,event_type")
    .eq("user_id", userID)
    .eq("review_status", "pending")
    .limit(200);
  if (error) throw error;

  const lifecycleByMerchant = new Map<
    string,
    Awaited<ReturnType<typeof merchantLifecycle>>
  >();
  const suppressionByMerchant = new Map<string, boolean>();
  for (const candidate of candidates ?? []) {
    const merchantKey = candidate.canonical_merchant_key;
    let lifecycle = lifecycleByMerchant.get(merchantKey);
    if (!lifecycle) {
      lifecycle = await merchantLifecycle(admin, userID, merchantKey);
      lifecycleByMerchant.set(merchantKey, lifecycle);
    }
    if (candidate.event_type === "canceled") {
      if (lifecycle.state === "current") {
        await resolveCandidateForLifecycle(
          admin,
          userID,
          candidate,
          "Later current renewal evidence was found.",
        );
      }
      continue;
    }
    let suppressed = suppressionByMerchant.get(merchantKey);
    if (suppressed === undefined) {
      suppressed = await merchantIsSuppressed(admin, userID, merchantKey);
      suppressionByMerchant.set(merchantKey, suppressed);
    }
    if (suppressed || lifecycle.state !== "current") {
      await resolveCandidateForLifecycle(
        admin,
        userID,
        candidate,
        suppressed
          ? "You chose not to receive discovery suggestions for this merchant."
          : lifecycleResolutionReason(
            lifecycle.state === "ended" ? "ended" : "uncertain",
          ),
      );
    }
  }
}

async function reviewCandidate(
  admin: AdminClient,
  userID: string,
  body: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const candidateID = requiredString(body.candidate_id, "candidate_id");
  const decision = requiredString(body.decision, "decision");
  if (decision !== "confirm" && decision !== "ignore") {
    throw new Error("Invalid decision");
  }
  const requestedStatus = decision === "confirm" ? "confirmed" : "ignored";

  const { data: candidate, error } = await admin
    .from("subscription_candidates")
    .select("*")
    .eq("id", candidateID)
    .eq("user_id", userID)
    .maybeSingle();
  if (error) throw error;
  if (!candidate) throw new Error("Candidate not found");

  const transition = reviewTransitionResult(
    candidate.review_status,
    requestedStatus,
  );
  if (transition === "idempotent") {
    return {
      candidate_id: candidate.id,
      review_status: candidate.review_status,
      applied_subscription_id: candidate.applied_subscription_id,
      idempotent: true,
    };
  }

  if (transition === "ignore") {
    const { error: ignoreError } = await admin.from("subscription_candidates")
      .update({
        review_status: "ignored",
        reviewed_at: new Date().toISOString(),
      }).eq("id", candidate.id).eq("user_id", userID).eq(
        "review_status",
        "pending",
      );
    if (ignoreError) throw ignoreError;
    await recordReviewOutcome(admin, userID, candidate, "ignored", body, null);
    return {
      candidate_id: candidate.id,
      review_status: "ignored",
      idempotent: false,
    };
  }

  const lifecycleAction = resolvedCandidateAction(candidate);
  const lifecycle = await merchantLifecycle(
    admin,
    userID,
    candidate.canonical_merchant_key,
  );
  const suppressed = lifecycleAction !== "cancel" &&
    await merchantIsSuppressed(admin, userID, candidate.canonical_merchant_key);
  const stale = lifecycleAction === "cancel"
    ? lifecycle.state !== "ended"
    : lifecycle.state !== "current" || suppressed;
  if (stale) {
    const reason = suppressed
      ? "You chose not to receive discovery suggestions for this merchant."
      : lifecycleAction === "cancel"
      ? "Later current renewal evidence was found."
      : lifecycle.state === "ended"
      ? lifecycleResolutionReason("ended")
      : lifecycleResolutionReason("uncertain");
    return await resolveCandidateForLifecycle(admin, userID, candidate, reason);
  }

  const edits = isRecord(body.edits) ? body.edits as CandidateEdits : {};
  const merchantName = normalizedMerchantEdit(
    edits.merchant_name,
    candidate.merchant_name,
  );
  const amount = normalizedNumberEdit(edits.amount, candidate.amount);
  const currency = normalizedCurrencyEdit(edits.currency, candidate.currency);
  const billingCycle = (edits.billing_cycle ?? candidate.billing_cycle) as
    | BillingCycle
    | null;
  const renewalDate = edits.renewal_date ?? candidate.renewal_date;
  const category =
    (edits.category ?? candidate.category) as SubscriptionCategory;
  const action = lifecycleAction;
  const issues = candidateConfirmationIssues({
    action,
    merchantName,
    amount,
    currency,
    billingCycle,
    renewalDate,
    matchedSubscriptionID: candidate.matched_subscription_id,
  });
  if (issues.length > 0) {
    throw new Error(`Invalid candidate: ${issues.join(", ")}`);
  }

  let appliedSubscriptionID: string;
  if (action === "cancel") {
    const { data: updated, error: cancelError } = await admin
      .from("subscriptions")
      .update({ status: "canceled" })
      .eq("id", candidate.matched_subscription_id)
      .eq("user_id", userID)
      .select("id")
      .maybeSingle();
    if (cancelError) throw cancelError;
    if (!updated) throw new Error("Matched subscription is unavailable");
    appliedSubscriptionID = updated.id;
  } else {
    const key = canonicalMerchantKey(merchantName);
    const updateValues = {
      user_id: userID,
      name: merchantName,
      price: amount,
      currency,
      billing_cycle: billingCycle,
      next_renewal_date: renewalDate,
      category,
      status: "active",
      icon_name: merchantName.slice(0, 1).toUpperCase(),
      brand_id: brandIDForMerchant(merchantName),
      tint_hex: tintForCategory(category),
      canonical_merchant_key: key,
    };
    if (candidate.matched_subscription_id) {
      const { data: updated, error: updateError } = await admin
        .from("subscriptions")
        .update(updateValues)
        .eq("id", candidate.matched_subscription_id)
        .eq("user_id", userID)
        .select("id")
        .maybeSingle();
      if (updateError) throw updateError;
      if (!updated) throw new Error("Matched subscription is unavailable");
      appliedSubscriptionID = updated.id;
    } else {
      const values = {
        ...updateValues,
        source: "email",
        source_key: `email:${key}`,
      };
      const { data: created, error: createError } = await admin
        .from("subscriptions")
        .upsert(values, { onConflict: "user_id,source_key" })
        .select("id")
        .single();
      if (createError) throw createError;
      appliedSubscriptionID = created.id;
    }
  }

  const reviewedAt = new Date().toISOString();
  const { error: candidateError } = await admin.from("subscription_candidates")
    .update({
      review_status: "confirmed",
      applied_subscription_id: appliedSubscriptionID,
      correction_payload: Object.keys(edits).length > 0 ? edits : null,
      reviewed_at: reviewedAt,
    }).eq("id", candidate.id).eq("user_id", userID).eq(
      "review_status",
      "pending",
    );
  if (candidateError) throw candidateError;
  await recordReviewOutcome(
    admin,
    userID,
    candidate,
    action === "cancel" ? "canceled" : editsDiffer(candidate, {
        merchantName,
        amount,
        currency,
        billingCycle,
        renewalDate,
        category,
      })
      ? "corrected"
      : "confirmed",
    body,
    {
      merchant_name: merchantName,
      amount,
      currency,
      billing_cycle: billingCycle,
      renewal_date: renewalDate,
      category,
    },
  );
  if (action !== "cancel") {
    const aliasKey = canonicalMerchantKey(candidate.merchant_name);
    const canonicalKey = canonicalMerchantKey(merchantName);
    if (aliasKey !== canonicalKey) {
      await admin.from("reviewed_merchant_aliases").upsert({
        user_id: userID,
        alias_key: aliasKey,
        canonical_merchant_key: canonicalKey,
      }, { onConflict: "user_id,alias_key" });
    }
  }
  const { error: eventError } = await admin.from("detected_billing_events")
    .update({
      applied: true,
      applied_subscription_id: appliedSubscriptionID,
    }).eq("id", candidate.detected_event_id).eq("user_id", userID);
  if (eventError) throw eventError;

  return {
    candidate_id: candidate.id,
    review_status: "confirmed",
    applied_subscription_id: appliedSubscriptionID,
    idempotent: false,
  };
}

function editsDiffer(
  candidate: Record<string, unknown>,
  value: Record<string, unknown>,
): boolean {
  return Object.entries(value).some(([key, item]) =>
    String(candidate[key] ?? "") !== String(item ?? "")
  );
}

async function recordReviewOutcome(
  admin: AdminClient,
  userID: string,
  candidate: Record<string, unknown>,
  outcome: "confirmed" | "corrected" | "ignored" | "suppressed" | "canceled",
  body: Record<string, unknown>,
  appliedFields: Record<string, unknown> | null,
): Promise<void> {
  const reason = typeof body.correction_reason === "string" &&
      [
        "wrong_merchant",
        "wrong_amount",
        "wrong_cycle",
        "not_a_subscription",
        "other",
      ].includes(body.correction_reason)
    ? body.correction_reason
    : null;
  const { error } = await admin.from("subscription_candidate_review_outcomes")
    .insert({
      user_id: userID,
      candidate_id: candidate.id,
      outcome,
      correction_reason: reason,
      proposed_fields: {
        merchant_name: candidate.merchant_name,
        amount: candidate.amount,
        currency: candidate.currency,
        billing_cycle: candidate.billing_cycle,
        renewal_date: candidate.renewal_date,
      },
      applied_fields: appliedFields ?? {},
    });
  if (error) throw error;
  await learnMerchantPriors(
    admin,
    userID,
    candidate.canonical_merchant_key,
    outcome,
    {
      billing_cycle: appliedFields?.billing_cycle,
      category: appliedFields?.category,
    },
  );
}

// Persist field priors learned from a person's own confirmed/corrected outcomes,
// mirroring how reviewed_merchant_aliases is written. derivePriorUpserts ignores
// non-learning outcomes, so this is safe to call on every review path.
async function learnMerchantPriors(
  admin: AdminClient,
  userID: string,
  canonicalMerchantKey: unknown,
  outcome: "confirmed" | "corrected" | "ignored" | "suppressed" | "canceled",
  applied: ReviewedFieldValues,
): Promise<void> {
  if (typeof canonicalMerchantKey !== "string" || !canonicalMerchantKey) return;
  if (outcome !== "confirmed" && outcome !== "corrected") return;
  const { data: existingRows, error } = await admin
    .from("merchant_review_priors")
    .select("canonical_merchant_key,field,value,evidence_strength")
    .eq("user_id", userID)
    .eq("canonical_merchant_key", canonicalMerchantKey);
  if (error) throw error;
  const upserts = derivePriorUpserts({
    outcome,
    canonicalMerchantKey,
    applied,
    existing: (existingRows ?? []) as MerchantReviewPrior[],
  });
  if (upserts.length === 0) return;
  const { error: upsertError } = await admin
    .from("merchant_review_priors")
    .upsert(
      upserts.map((row) => ({ user_id: userID, ...row })),
      { onConflict: "user_id,canonical_merchant_key,field" },
    );
  if (upsertError) throw upsertError;
}

async function suppressCandidate(
  admin: AdminClient,
  userID: string,
  body: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const candidateID = requiredString(body.candidate_id, "candidate_id");
  const { data: candidate, error } = await admin
    .from("subscription_candidates")
    .select(
      "id,review_status,event_type,suggested_action,canonical_merchant_key",
    )
    .eq("id", candidateID)
    .eq("user_id", userID)
    .maybeSingle();
  if (error) throw error;
  if (!candidate) throw new Error("Candidate not found");
  if (candidate.review_status !== "pending") {
    return {
      candidate_id: candidate.id,
      review_status: candidate.review_status,
      idempotent: true,
    };
  }
  if (
    candidate.event_type === "canceled" ||
    candidate.suggested_action === "cancel"
  ) {
    throw new Error("Candidate cannot be suppressed");
  }
  const merchantKey = candidate.canonical_merchant_key;
  const { error: suppressionError } = await admin.from(
    "merchant_discovery_suppressions",
  ).upsert({
    user_id: userID,
    canonical_merchant_key: merchantKey,
    reason: "unused",
  }, { onConflict: "user_id,canonical_merchant_key" });
  if (suppressionError) throw suppressionError;
  await resolvePendingDiscoveryCandidates(
    admin,
    userID,
    merchantKey,
    "You chose not to receive discovery suggestions for this merchant.",
  );
  return {
    candidate_id: candidate.id,
    review_status: "ignored",
    suppressed: true,
    idempotent: false,
  };
}

async function unsuppressMerchant(
  admin: AdminClient,
  userID: string,
  merchantKey: string,
): Promise<Record<string, unknown>> {
  if (!/^[a-z0-9][a-z0-9-]{0,79}$/.test(merchantKey)) {
    throw new Error("Invalid canonical_merchant_key");
  }
  const { error } = await admin.from("merchant_discovery_suppressions")
    .delete()
    .eq("user_id", userID)
    .eq("canonical_merchant_key", merchantKey);
  if (error) throw error;
  return { canonical_merchant_key: merchantKey, unsuppressed: true };
}

async function resolveCandidateForLifecycle(
  admin: AdminClient,
  userID: string,
  candidate: Record<string, unknown>,
  reason: string,
): Promise<Record<string, unknown>> {
  const { error } = await admin.from("subscription_candidates")
    .update({
      review_status: "ignored",
      system_resolution_reason: reason,
      system_resolved_at: new Date().toISOString(),
      reviewed_at: new Date().toISOString(),
    })
    .eq("id", candidate.id)
    .eq("user_id", userID)
    .eq("review_status", "pending");
  if (error) throw error;
  return {
    candidate_id: candidate.id,
    review_status: "ignored",
    system_resolution_reason: reason,
    idempotent: false,
  };
}

function resolvedCandidateAction(
  candidate: Record<string, unknown>,
): ReturnType<typeof classifyCandidateAction> {
  const suggestedAction = String(candidate.suggested_action);
  if (suggestedAction !== "review") {
    return suggestedAction as ReturnType<typeof classifyCandidateAction>;
  }
  if (candidate.event_type === "canceled") return "review";
  return candidate.matched_subscription_id ? "update" : "add";
}

async function connectionSummaries(
  admin: AdminClient,
  userID: string,
): Promise<Array<Record<string, unknown>>> {
  const { data: connections, error } = await admin
    .from("email_connections")
    .select(
      "id,provider,email,last_scanned_at,last_automatic_scan_at,last_error,automatic_monitoring_enabled,created_at",
    )
    .eq("user_id", userID)
    .order("created_at", { ascending: true });
  if (error) throw error;
  if (!connections || connections.length === 0) return [];

  const connectionIDs = connections.map((connection) => connection.id);
  const { data: syncStates, error: syncError } = await admin
    .from("mail_sync_states")
    .select("connection_id,last_successful_at,last_error")
    .eq("user_id", userID)
    .in("connection_id", connectionIDs);
  if (syncError) throw syncError;
  const { data: activeJobs, error: jobError } = await admin
    .from("email_scan_jobs")
    .select("connection_id,status")
    .eq("user_id", userID)
    .in("connection_id", connectionIDs)
    .in("status", ["queued", "running"]);
  if (jobError) throw jobError;
  const { data: watches, error: watchError } = await admin
    .from("inbox_monitoring_watches")
    .select("connection_id,health,last_error,expires_at")
    .eq("user_id", userID)
    .in("connection_id", connectionIDs);
  if (watchError) throw watchError;

  return connections.map((connection) => {
    const sync = (syncStates ?? []).find((state) =>
      state.connection_id === connection.id
    );
    const active = (activeJobs ?? []).find((job) =>
      job.connection_id === connection.id
    );
    const watch = (watches ?? []).find((item) =>
      item.connection_id === connection.id
    );
    return {
      id: connection.id,
      provider: connection.provider,
      redacted_email: redactEmailAddress(connection.email),
      last_scanned_at: sync?.last_successful_at ?? connection.last_scanned_at,
      health: connection.last_error || sync?.last_error
        ? "attention"
        : "connected",
      scan_status: active?.status ?? "idle",
      automatic_monitoring_enabled:
        connection.automatic_monitoring_enabled === true,
      monitoring_health: watch?.health ?? "not_configured",
      monitoring_error: watch?.last_error ?? null,
      monitoring_expires_at: watch?.expires_at ?? null,
      last_automatic_scan_at: connection.last_automatic_scan_at ?? null,
      monitoring_fallback_active:
        connection.automatic_monitoring_enabled === true,
    };
  });
}

async function disconnectConnection(
  admin: AdminClient,
  userID: string,
  connectionID: string,
): Promise<Record<string, unknown>> {
  const { data: connection, error } = await admin
    .from("email_connections")
    .select(
      "id,user_id,provider,email,encrypted_tokens,last_scanned_at,created_at",
    )
    .eq("id", connectionID)
    .eq("user_id", userID)
    .maybeSingle();
  if (error) throw error;
  if (!connection) throw new Error("Connection not found");

  await stopInboxMonitoring(admin, connectionID);

  let remoteRevoked = false;
  try {
    const tokens = await decryptJSON<StoredTokens>(connection.encrypted_tokens);
    if (connection.provider === "google") {
      const response = await fetch(
        `https://oauth2.googleapis.com/revoke?token=${
          encodeURIComponent(tokens.refresh_token ?? tokens.access_token)
        }`,
        {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
        },
      );
      remoteRevoked = response.ok;
    }
  } catch {
    remoteRevoked = false;
  }

  const { data: jobs } = await admin
    .from("email_scan_jobs")
    .select("scan_run_id")
    .eq("connection_id", connectionID)
    .eq("user_id", userID)
    .in("status", ["queued", "running"]);
  const runIDs = (jobs ?? []).map((job) => job.scan_run_id);
  if (runIDs.length > 0) {
    await admin.from("email_scan_runs").update({
      status: "failed",
      stage: "failed",
      error_message: "Inbox disconnected.",
      completed_at: new Date().toISOString(),
    }).in("id", runIDs).eq("user_id", userID);
  }

  const { error: deleteError } = await admin
    .from("email_connections")
    .delete()
    .eq("id", connectionID)
    .eq("user_id", userID);
  if (deleteError) throw deleteError;
  return { disconnected: true, remote_revoked: remoteRevoked };
}

async function clearScanHistory(
  admin: AdminClient,
  userID: string,
): Promise<Record<string, unknown>> {
  const { data: runs, error: readError } = await admin
    .from("email_scan_runs")
    .select("id")
    .eq("user_id", userID);
  if (readError) throw readError;
  const { error } = await admin.from("email_scan_runs").delete().eq(
    "user_id",
    userID,
  );
  if (error) throw error;
  return { cleared: true, runs_deleted: runs?.length ?? 0 };
}

async function fetchGmailBatch(
  accessToken: string,
  sync: SyncState | null,
  continuation: string | null,
): Promise<ProviderBatch> {
  let messageIDs: string[] = [];
  let cursorValue = "";
  let nextPageToken: string | null = null;
  if (continuation !== null || !sync) {
    const bootstrap = await gmailMailboxPage(
      accessToken,
      continuation,
      initialMailboxLookbackDays,
    );
    messageIDs = bootstrap.messageIDs;
    cursorValue = bootstrap.historyID;
    nextPageToken = bootstrap.nextPageToken;
  } else if (sync.cursor_kind === "gmail_history") {
    try {
      const history = await gmailHistory(accessToken, sync.cursor_value);
      messageIDs = history.messageIDs;
      cursorValue = history.historyID;
    } catch (error) {
      if (!errorMessage(error, "").includes("cursor expired")) throw error;
      const bootstrap = await gmailRecentPage(
        accessToken,
        cursorRecoveryLookbackDays,
      );
      messageIDs = bootstrap.messageIDs;
      cursorValue = bootstrap.historyID;
    }
  }

  const metadata = (await mapWithConcurrency(
    [...new Set(messageIDs)].slice(
      0,
      nextPageToken === null
        ? maximumIncrementalMessages
        : maximumMessagesPerHistoricalPage,
    ),
    6,
    async (id) => {
      // Skip a single unreadable message (e.g. a 404 for one deleted between
      // the history feed and this fetch) instead of failing the whole listing.
      try {
        return await fetchGmailMetadata(accessToken, id);
      } catch {
        return null;
      }
    },
  )).filter((item): item is MailMetadata => item !== null);
  return {
    metadata,
    cursorKind: "gmail_history",
    cursorValue,
    continuation: nextPageToken,
    fullMessage: (item) => fetchGmailFullMessage(accessToken, item),
  };
}

async function gmailMailboxPage(
  accessToken: string,
  pageToken: string | null,
  lookbackDays: number,
): Promise<
  { messageIDs: string[]; historyID: string; nextPageToken: string | null }
> {
  const params = new URLSearchParams({
    maxResults: String(maximumMessagesPerHistoricalPage),
    q: gmailHistoricalQuery(lookbackDays),
  });
  if (pageToken) params.set("pageToken", pageToken);
  const response = await providerFetch(
    `https://gmail.googleapis.com/gmail/v1/users/me/messages?${params}`,
    accessToken,
    "Gmail could not be read. Reconnect your inbox.",
  );
  const payload = await response.json();

  const profile = await providerFetch(
    "https://gmail.googleapis.com/gmail/v1/users/me/profile",
    accessToken,
    "Gmail profile could not be read.",
  );
  const profilePayload = await profile.json();
  return {
    messageIDs: (payload.messages ?? []).map((message: { id: string }) =>
      message.id
    ),
    historyID: String(profilePayload.historyId),
    nextPageToken: typeof payload.nextPageToken === "string"
      ? payload.nextPageToken
      : null,
  };
}

async function gmailRecentPage(
  accessToken: string,
  days: number,
): Promise<{ messageIDs: string[]; historyID: string }> {
  const params = new URLSearchParams({
    maxResults: String(maximumIncrementalMessages),
    q: `newer_than:${days}d`,
  });
  const response = await providerFetch(
    `https://gmail.googleapis.com/gmail/v1/users/me/messages?${params}`,
    accessToken,
    "Gmail could not be read. Reconnect your inbox.",
  );
  const payload = await response.json();
  const profile = await providerFetch(
    "https://gmail.googleapis.com/gmail/v1/users/me/profile",
    accessToken,
    "Gmail profile could not be read.",
  );
  const profilePayload = await profile.json();
  return {
    messageIDs: (payload.messages ?? []).map((message: { id: string }) =>
      message.id
    ),
    historyID: String(profilePayload.historyId),
  };
}

async function gmailHistory(
  accessToken: string,
  startHistoryID: string,
): Promise<{ messageIDs: string[]; historyID: string }> {
  const messageIDs: string[] = [];
  let pageToken: string | null = null;
  let historyID = startHistoryID;
  do {
    const params = new URLSearchParams({
      startHistoryId: startHistoryID,
      historyTypes: "messageAdded",
      labelId: "INBOX",
      maxResults: "100",
    });
    if (pageToken) params.set("pageToken", pageToken);
    const response = await fetch(
      `https://gmail.googleapis.com/gmail/v1/users/me/history?${params}`,
      { headers: { Authorization: `Bearer ${accessToken}` } },
    );
    if (response.status === 404) throw new Error("Gmail cursor expired");
    if (!response.ok) {
      throw new Error("Gmail history could not be read. Reconnect your inbox.");
    }
    const payload = await response.json();
    for (const history of payload.history ?? []) {
      for (const added of history.messagesAdded ?? []) {
        if (added.message?.id) messageIDs.push(added.message.id);
      }
    }
    historyID = String(payload.historyId ?? historyID);
    pageToken = payload.nextPageToken ?? null;
  } while (pageToken && messageIDs.length < maximumIncrementalMessages);
  return { messageIDs, historyID };
}

async function fetchGmailMetadata(
  accessToken: string,
  id: string,
): Promise<MailMetadata> {
  const params = new URLSearchParams({
    format: "metadata",
    metadataHeaders: "Subject",
  });
  params.append("metadataHeaders", "From");
  const response = await providerFetch(
    `https://gmail.googleapis.com/gmail/v1/users/me/messages/${
      encodeURIComponent(id)
    }?${params}`,
    accessToken,
    "A Gmail message could not be read.",
  );
  const message = await response.json();
  const headers = message.payload?.headers ?? [];
  return {
    id,
    subject: gmailHeader(headers, "Subject"),
    sender: gmailHeader(headers, "From"),
    received_at: new Date(Number(message.internalDate)).toISOString(),
    snippet: message.snippet ?? "",
  };
}

async function fetchGmailFullMessage(
  accessToken: string,
  metadata: MailMetadata,
): Promise<MailMessage> {
  const response = await providerFetch(
    `https://gmail.googleapis.com/gmail/v1/users/me/messages/${
      encodeURIComponent(metadata.id)
    }?format=full`,
    accessToken,
    "A Gmail message could not be read.",
  );
  const message = await response.json();
  return {
    ...metadata,
    content: `${message.snippet ?? ""}\n${gmailText(message.payload ?? {})}`,
  };
}

async function fetchMicrosoftBatch(
  accessToken: string,
  sync: SyncState | null,
  continuation: string | null,
): Promise<ProviderBatch> {
  if (continuation !== null || !sync) {
    return await fetchMicrosoftMailboxPage(
      accessToken,
      continuation,
      initialMailboxLookbackDays,
    );
  }
  try {
    return await fetchMicrosoftBatchAttempt(accessToken, sync);
  } catch (error) {
    if (
      sync?.cursor_kind === "microsoft_delta" &&
      errorMessage(error, "").includes("cursor expired")
    ) {
      return await fetchMicrosoftMailboxPage(
        accessToken,
        null,
        cursorRecoveryLookbackDays,
      );
    }
    throw error;
  }
}

async function fetchMicrosoftBatchAttempt(
  accessToken: string,
  sync: SyncState | null,
): Promise<ProviderBatch> {
  let nextURL: string;
  if (
    sync?.cursor_kind === "microsoft_delta" &&
    isMicrosoftGraphURL(sync.cursor_value)
  ) {
    nextURL = sync.cursor_value;
  } else throw new Error("Microsoft synchronization cursor is unavailable.");

  const metadata: MailMetadata[] = [];
  let deltaLink: string | null = null;
  let pages = 0;
  while (nextURL && pages < 8) {
    const response = await providerFetch(
      nextURL,
      accessToken,
      sync
        ? "Microsoft synchronization cursor expired."
        : "Microsoft mail could not be read. Reconnect your inbox.",
    );
    const payload = await response.json();
    for (const message of payload.value ?? []) {
      if (message["@removed"] || !message.id) continue;
      metadata.push({
        id: message.id,
        subject: message.subject ?? "",
        sender: message.from?.emailAddress?.address ?? "",
        received_at: message.receivedDateTime,
        snippet: message.bodyPreview ?? "",
      });
    }
    pages += 1;
    if (payload["@odata.deltaLink"]) deltaLink = payload["@odata.deltaLink"];
    const candidateNext = payload["@odata.nextLink"];
    nextURL =
      typeof candidateNext === "string" && isMicrosoftGraphURL(candidateNext)
        ? candidateNext
        : "";
  }
  if (!deltaLink) {
    throw new Error("Microsoft mailbox window exceeded the safe scan limit.");
  }

  return {
    metadata: metadata.slice(0, maximumIncrementalMessages),
    cursorKind: "microsoft_delta",
    cursorValue: deltaLink,
    continuation: null,
    fullMessage: (item) => fetchMicrosoftFullMessage(accessToken, item),
  };
}

async function fetchMicrosoftMailboxPage(
  accessToken: string,
  continuation: string | null,
  lookbackDays: number,
): Promise<ProviderBatch> {
  const params = new URLSearchParams({
    "$select": "id,subject,from,receivedDateTime,bodyPreview",
    "$top": String(maximumMessagesPerHistoricalPage),
    "$filter": microsoftHistoricalFilter(lookbackDays),
    "$orderby": "receivedDateTime desc",
  });
  const nextURL = continuation && isMicrosoftGraphURL(continuation)
    ? continuation
    : `https://graph.microsoft.com/v1.0/me/messages/delta?${params}`;
  const response = await providerFetch(
    nextURL,
    accessToken,
    "Microsoft mail could not be read. Reconnect your inbox.",
  );
  const payload = await response.json();
  const metadata = (payload.value ?? []).flatMap(
    (message: Record<string, unknown>) => {
      if (message["@removed"] || typeof message.id !== "string") return [];
      return [
        {
          id: message.id,
          subject: typeof message.subject === "string" ? message.subject : "",
          sender: typeof (message.from as
              | { emailAddress?: { address?: unknown } }
              | undefined)?.emailAddress?.address === "string"
            ? (message.from as { emailAddress: { address: string } })
              .emailAddress.address
            : "",
          received_at: typeof message.receivedDateTime === "string"
            ? message.receivedDateTime
            : new Date().toISOString(),
          snippet: typeof message.bodyPreview === "string"
            ? message.bodyPreview
            : "",
        } satisfies MailMetadata,
      ];
    },
  );
  const next = typeof payload["@odata.nextLink"] === "string" &&
      isMicrosoftGraphURL(payload["@odata.nextLink"])
    ? payload["@odata.nextLink"]
    : null;
  const delta = typeof payload["@odata.deltaLink"] === "string" &&
      isMicrosoftGraphURL(payload["@odata.deltaLink"])
    ? payload["@odata.deltaLink"]
    : "";
  if (!next && !delta) {
    throw new Error("Microsoft mailbox cursor was not returned.");
  }
  return {
    metadata,
    cursorKind: "microsoft_delta",
    cursorValue: delta,
    continuation: next,
    fullMessage: (item) => fetchMicrosoftFullMessage(accessToken, item),
  };
}

async function fetchMicrosoftFullMessage(
  accessToken: string,
  metadata: MailMetadata,
): Promise<MailMessage> {
  const params = new URLSearchParams({
    "$select": "id,subject,from,receivedDateTime,bodyPreview,body",
  });
  const response = await providerFetch(
    `https://graph.microsoft.com/v1.0/me/messages/${
      encodeURIComponent(metadata.id)
    }?${params}`,
    accessToken,
    "A Microsoft message could not be read.",
  );
  const message = await response.json();
  return {
    ...metadata,
    content: `${message.bodyPreview ?? ""}\n${message.body?.content ?? ""}`,
  };
}

function uniqueSubscriptionMatch(
  subscriptions: Array<Record<string, unknown>>,
  merchantName: string,
  key: string,
  provider: Provider,
): Record<string, unknown> | null {
  const brandID = brandIDForMerchant(merchantName);
  const matches = subscriptions.filter((subscription) => {
    const existingKey = typeof subscription.canonical_merchant_key === "string"
      ? subscription.canonical_merchant_key
      : null;
    const sourceKey = typeof subscription.source_key === "string"
      ? subscription.source_key
      : null;
    const name = typeof subscription.name === "string" ? subscription.name : "";
    const existingBrandID = typeof subscription.brand_id === "string"
      ? subscription.brand_id
      : null;
    return existingKey === key ||
      sourceKey === `email:${key}` ||
      sourceKey === `${provider}:${key}` ||
      canonicalMerchantKey(name) === key ||
      (brandID !== null && existingBrandID === brandID);
  });
  const uniqueMatches = [
    ...new Map(matches.map((match) => [String(match.id), match])).values(),
  ];
  return uniqueMatches.length === 1 ? uniqueMatches[0] : null;
}

function semanticValidationIssues(
  event: BillingEvent,
  action: string,
  matchedStatus: unknown,
): string[] {
  const issues: string[] = [];
  if (event.confidence < 0.72) issues.push("low_model_confidence");
  if (action !== "cancel") {
    if (event.amount === null) issues.push("missing_amount");
    if (event.currency === null) issues.push("missing_currency");
    if (event.billing_cycle === null) issues.push("missing_billing_cycle");
    if (event.renewal_date === null) issues.push("missing_renewal_date");
  }
  if (action === "review") issues.push("merchant_match_required");
  if (matchedStatus === "canceled" && event.event_type !== "canceled") {
    issues.push("reactivation_requires_review");
  }
  return [...new Set(issues)];
}

function gmailHeader(
  headers: Array<{ name: string; value: string }>,
  name: string,
): string {
  return headers.find((item) => item.name.toLowerCase() === name.toLowerCase())
    ?.value ?? "";
}

function gmailText(part: Record<string, unknown>): string {
  const body = part.body as { data?: string } | undefined;
  const mimeType = part.mimeType as string | undefined;
  if (body?.data && (mimeType === "text/plain" || mimeType === "text/html")) {
    const normalized = body.data.replace(/-/g, "+").replace(/_/g, "/");
    try {
      return new TextDecoder().decode(
        Uint8Array.from(
          atob(normalized),
          (character) => character.charCodeAt(0),
        ),
      );
    } catch {
      return "";
    }
  }
  const parts = part.parts as Record<string, unknown>[] | undefined;
  return parts?.map(gmailText).join("\n") ?? "";
}

async function providerFetch(
  url: string,
  accessToken: string,
  failureMessage: string,
): Promise<Response> {
  const response = await fetch(url, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!response.ok) throw new Error(failureMessage);
  return response;
}

function isMicrosoftGraphURL(value: string): boolean {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && url.hostname === "graph.microsoft.com";
  } catch {
    return false;
  }
}

function senderDomain(value: string): string | null {
  const match = value.toLowerCase().match(/@([a-z0-9.-]+\.[a-z]{2,})/);
  return match?.[1] ?? null;
}

async function mapWithConcurrency<T, R>(
  values: T[],
  concurrency: number,
  transform: (value: T) => Promise<R>,
): Promise<R[]> {
  const results = new Array<R>(values.length);
  let index = 0;
  async function worker(): Promise<void> {
    while (index < values.length) {
      const current = index;
      index += 1;
      results[current] = await transform(values[current]);
    }
  }
  await Promise.all(
    Array.from({ length: Math.min(concurrency, values.length) }, worker),
  );
  return results;
}

async function updateRun(
  admin: AdminClient,
  runID: string,
  values: Record<string, unknown>,
): Promise<void> {
  const { error } = await admin.from("email_scan_runs").update(values).eq(
    "id",
    runID,
  );
  if (error) throw error;
}

async function addRunMetrics(
  admin: AdminClient,
  runID: string,
  additions: {
    messages_scanned: number;
    candidate_messages: number;
    events_detected: number;
    validation_failures: number;
  },
): Promise<{ events_detected: number }> {
  const { data: run, error: readError } = await admin
    .from("email_scan_runs")
    .select(
      "messages_scanned,candidate_messages,events_detected,validation_failures",
    )
    .eq("id", runID)
    .single();
  if (readError || !run) throw readError ?? new Error("Scan run not found");
  const next = {
    messages_scanned: Number(run.messages_scanned ?? 0) +
      additions.messages_scanned,
    candidate_messages: Number(run.candidate_messages ?? 0) +
      additions.candidate_messages,
    events_detected: Number(run.events_detected ?? 0) +
      additions.events_detected,
    validation_failures: Number(run.validation_failures ?? 0) +
      additions.validation_failures,
  };
  await updateRun(admin, runID, next);
  return { events_detected: next.events_detected };
}

async function scanRunBatchID(
  admin: AdminClient,
  runID: string,
): Promise<string> {
  const { data, error } = await admin.from("email_scan_runs")
    .select("batch_id")
    .eq("id", runID)
    .single();
  if (error || !data?.batch_id) {
    throw error ?? new Error("Scan batch not found");
  }
  return String(data.batch_id);
}

function queueWorkerContinuation(userID: string, batchID: string): void {
  const endpoint = `${mustEnv("SUPABASE_URL")}/functions/v1/email-scan`;
  const work = fetch(endpoint, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-renewa-monitor-secret": mustEnv("INBOX_MONITOR_SECRET"),
    },
    body: JSON.stringify({
      action: "continue",
      user_id: userID,
      batch_id: batchID,
    }),
  }).then((response) => {
    if (!response.ok) {
      throw new Error(`Could not continue mailbox scan (${response.status})`);
    }
  }).catch((error) =>
    console.error("mailbox scan continuation failed", safeErrorMessage(error))
  );
  const runtime = (globalThis as unknown as {
    EdgeRuntime?: { waitUntil: (promise: Promise<unknown>) => void };
  }).EdgeRuntime;
  if (runtime) runtime.waitUntil(work);
}

function aggregateStage(
  runs: Array<Record<string, unknown>>,
  status: string,
): string {
  if (status === "failed") return "failed";
  if (status === "partial") return "completed";
  if (status === "completed") {
    return runs.some((run) => run.stage === "review_ready")
      ? "review_ready"
      : "completed";
  }
  const order = ["queued", "fetching", "filtering", "extracting", "reasoning"];
  for (const stage of order.toReversed()) {
    if (runs.some((run) => run.stage === stage)) return stage;
  }
  return "queued";
}

function sum(rows: Array<Record<string, unknown>>, key: string): number {
  return rows.reduce((total, row) => total + Number(row[key] ?? 0), 0);
}

function uniqueStrings(values: unknown[]): string[] {
  return [
    ...new Set(
      values.filter((value): value is string =>
        typeof value === "string" && value.length > 0
      ),
    ),
  ];
}

function requiredString(value: unknown, name: string): string {
  if (typeof value !== "string" || !value.trim()) {
    throw new Error(`${name} is required`);
  }
  return value.trim();
}

function optionalString(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function stringOrNull(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function numberOrNull(value: unknown): number | null {
  const number = typeof value === "number" ? value : Number(value);
  return Number.isFinite(number) ? number : null;
}

function normalizedMerchantEdit(value: unknown, fallback: unknown): string {
  const merchant = typeof value === "string"
    ? value.trim()
    : String(fallback ?? "").trim();
  return merchant.slice(0, 120);
}

function normalizedNumberEdit(
  value: unknown,
  fallback: unknown,
): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  const parsed = typeof fallback === "number" ? fallback : Number(fallback);
  return Number.isFinite(parsed) ? parsed : null;
}

function normalizedCurrencyEdit(
  value: unknown,
  fallback: unknown,
): string | null {
  const currency = typeof value === "string"
    ? value
    : typeof fallback === "string"
    ? fallback
    : null;
  return currency?.toUpperCase().slice(0, 3) ?? null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function safeErrorMessage(error: unknown): string {
  const message = errorMessage(error, "Email scan failed");
  if (/token|secret|authorization|bearer/i.test(message)) {
    return "Inbox authorization needs attention.";
  }
  return message.slice(0, 300);
}

function errorMessage(error: unknown, fallback: string): string {
  if (error instanceof Error) return error.message;
  if (
    typeof error === "object" &&
    error !== null &&
    "message" in error &&
    typeof error.message === "string"
  ) {
    return error.message;
  }
  return fallback;
}
