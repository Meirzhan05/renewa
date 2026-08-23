import { handleOptions, json } from "../_shared/http.ts";
import {
  adminClient,
  authenticatedUser,
  mustEnv,
} from "../_shared/supabase.ts";
import { decryptJSON, encryptJSON, sha256 } from "../_shared/crypto.ts";
import { Provider, refreshTokens, StoredTokens } from "../_shared/oauth.ts";
import {
  BillingCycle,
  BillingEvent,
  brandIDForMerchant,
  buildExtractionMessages,
  canCreateLifecycleCandidate,
  candidateConfirmationIssues,
  canonicalMerchantKey,
  classifyCandidateAction,
  isLikelyBillingCandidate,
  MailMessage,
  MailMetadata,
  reconcileMerchantLifecycle,
  redactEmailAddress,
  resolveMerchantIdentity,
  reviewTransitionResult,
  SubscriptionCategory,
  tintForCategory,
  validateExtractionEnvelope,
} from "../_shared/email-discovery.ts";
import { buildLearningSummary } from "../_shared/inbox-scan-dashboard.ts";
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
  billingCycleClarificationDraft,
  identityClarificationDraft,
  isClarificationAnswerAllowed,
  lifecycleClarificationDraft,
  shouldSupersedeClarification,
  type InboxClarificationChoice,
  type InboxClarificationDraft,
  type InboxClarificationKind,
} from "../_shared/inbox-clarification-policy.ts";
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
        scheduleUserJobs(admin, user.id, scanID);
        return json(await scanStatus(admin, user.id, scanID));
      }
      case "review":
        return json(await reviewCandidate(admin, user.id, body));
      case "resolve_clarification":
        return json(await resolveClarification(admin, user.id, body));
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
        : message === "Candidate not found" || message === "Clarification request not found" ||
            message === "Connection not found"
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
  const work = processUserJobs(admin, userID, batchID).catch((error) => {
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
      const queuedNextPage = await processConnectionJob(
        admin,
        userID,
        job.scan_run_id,
        job.connection_id,
        job.page_number,
        job.provider_continuation,
      );
      needsFollowup = needsFollowup || queuedNextPage;
      await admin.from("email_scan_jobs").update({
        status: "completed",
        completed_at: new Date().toISOString(),
      }).eq("id", job.id);
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
        status: retryable ? "running" : "failed",
        stage: retryable ? "queued" : "failed",
        error_message: message,
        completed_at: retryable ? null : new Date().toISOString(),
      }).eq("id", job.scan_run_id);
      await publishBatchNotificationState(admin, userID, job.batch_id);
    }
  }
  if (needsFollowup && batchID) queueWorkerContinuation(userID, batchID);
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
): Promise<boolean> {
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
    stage: "filtering",
  });
  const likely = providerBatch.metadata
    .filter(isLikelyBillingCandidate);
  const metadataByID = new Map(likely.map((item) => [item.id, item]));
  await updateRun(admin, runID, {
    stage: "extracting",
  });

  const { data: subscriptions, error: subscriptionsError } = await admin
    .from("subscriptions")
    .select("id,name,source_key,canonical_merchant_key,brand_id,status")
    .eq("user_id", userID);
  if (subscriptionsError) throw subscriptionsError;
  const { data: reviewedAliases, error: aliasError } = await admin
    .from("reviewed_merchant_aliases")
    .select("alias_key,canonical_merchant_key")
    .eq("user_id", userID);
  if (aliasError) throw aliasError;
  const { data: reviewPriors, error: priorsError } = await admin
    .from("merchant_review_priors")
    .select("canonical_merchant_key,field,value,evidence_strength")
    .eq("user_id", userID);
  if (priorsError) throw priorsError;
  const priorsByMerchant = new Map<string, MerchantReviewPrior[]>();
  for (const prior of (reviewPriors ?? []) as MerchantReviewPrior[]) {
    const list = priorsByMerchant.get(prior.canonical_merchant_key) ?? [];
    list.push(prior);
    priorsByMerchant.set(prior.canonical_merchant_key, list);
  }

  let detected = 0;
  let validationFailures = 0;
  const extractionResults = await mapWithConcurrency(
    likely,
    3,
    async (metadata) => {
      // Tolerate a single unreadable message (e.g. a provider 404 for a message
      // deleted between listing and fetch). Skipping and counting it keeps one
      // bad message from aborting the whole scan and degrading the inbox.
      try {
        const message = await providerBatch.fullMessage(metadata);
        return await extractBillingEvent(message);
      } catch {
        return { event: null, abstainReason: null, issues: ["message_fetch_failed"] };
      }
    },
  );
  for (const extraction of extractionResults) {
    if (extraction.issues.length > 0) {
      validationFailures += 1;
      continue;
    }
    if (!extraction.event) continue;

    const event = extraction.event;
    const sourceReceivedAt = metadataByID.get(event.message_id)?.received_at;
    if (!sourceReceivedAt) {
      validationFailures += 1;
      continue;
    }
    const key = canonicalMerchantKey(event.merchant_name);
    const identity = resolveMerchantIdentity({
      merchant_name: event.merchant_name,
      sender_domain: senderDomain(
        metadataByID.get(event.message_id)?.sender ?? "",
      ),
      canonical_merchant_key: key,
      aliases: (reviewedAliases ?? []) as Array<
        { alias_key: string; canonical_merchant_key: string }
      >,
      known_keys: [
        ...new Set([
          key,
          ...(subscriptions ?? []).map((item) =>
            String(item.canonical_merchant_key ?? "")
          ).filter(Boolean),
        ]),
      ],
    });
    if (identity.state !== "resolved") {
      if (identity.state === "ambiguous") {
        const providerMessageFingerprint = await sha256(
          `${provider}:${event.message_id}`,
        );
        const { data: savedEvent, error: eventError } = await admin
          .from("detected_billing_events")
          .upsert({
            user_id: userID,
            scan_run_id: runID,
            provider,
            provider_message_id: providerMessageFingerprint,
            event_type: event.event_type,
            merchant_name: event.merchant_name,
            canonical_merchant_key: key,
            amount: event.amount,
            currency: event.currency,
            billing_cycle: event.billing_cycle,
            event_date: event.event_date,
            renewal_date: event.renewal_date,
            source_received_at: sourceReceivedAt,
            confidence: event.confidence,
            evidence: event.evidence.slice(0, 280),
            validation_state: "valid",
            validation_issues: [],
            schema_version: extractionSchemaVersion,
            model_identifier: modelIdentifier(),
          }, {
            onConflict: "user_id,provider,provider_message_id,event_type",
            ignoreDuplicates: true,
          })
          .select("id")
          .maybeSingle();
        if (eventError) throw eventError;
        if (savedEvent) {
          const lifecycle = await merchantLifecycle(admin, userID, key);
          const bundleID = await upsertEvidenceBundle(
            admin,
            userID,
            key,
            lifecycle,
            savedEvent.id,
            identity.reason,
          );
          const draft = identityClarificationDraft({
            event,
            receivedAt: sourceReceivedAt,
            candidateKeys: identity.candidate_keys,
          });
          if (draft) {
            await upsertClarificationRequest(admin, userID, {
              draft,
              merchantName: event.merchant_name,
              merchantKey: key,
              evidenceBundleID: bundleID,
              detectedEventID: savedEvent.id,
              sourceReceivedAt,
              context: {
                candidate_keys: identity.candidate_keys,
                evidence_events: [{
                  event_type: event.event_type,
                  merchant_name: event.merchant_name,
                  received_at: sourceReceivedAt,
                }],
              },
            });
          }
        }
      }
      await updateRun(admin, runID, { withheld_ambiguities: 1 });
      continue;
    }
    const matched = uniqueSubscriptionMatch(
      subscriptions ?? [],
      event.merchant_name,
      identity.canonical_merchant_key,
      provider,
    );
    const matchedID = typeof matched?.id === "string" ? matched.id : null;
    const providerMessageFingerprint = await sha256(
      `${provider}:${event.message_id}`,
    );

    const { data: savedEvent, error: eventError } = await admin
      .from("detected_billing_events")
      .upsert({
        user_id: userID,
        scan_run_id: runID,
        provider,
        provider_message_id: providerMessageFingerprint,
        event_type: event.event_type,
        merchant_name: event.merchant_name,
        canonical_merchant_key: identity.canonical_merchant_key,
        amount: event.amount,
        currency: event.currency,
        billing_cycle: event.billing_cycle,
        event_date: event.event_date,
        renewal_date: event.renewal_date,
        source_received_at: sourceReceivedAt,
        confidence: event.confidence,
        evidence: event.evidence.slice(0, 280),
        validation_state: "valid",
        validation_issues: [],
        schema_version: extractionSchemaVersion,
        model_identifier: modelIdentifier(),
      }, {
        onConflict: "user_id,provider,provider_message_id,event_type",
        ignoreDuplicates: true,
      })
      .select("id")
      .maybeSingle();
    if (eventError) throw eventError;
    if (!savedEvent) continue;

    const lifecycle = await merchantLifecycle(
      admin,
      userID,
      identity.canonical_merchant_key,
    );
    const bundleID = await upsertEvidenceBundle(
      admin,
      userID,
      identity.canonical_merchant_key,
      lifecycle,
      savedEvent.id,
      identity.reason,
    );
    // Overlay the person's learned priors as proposed defaults. This never
    // rewrites the raw detected_billing_events row (already saved above), so
    // reconcileMerchantLifecycle inputs stay untouched; priors only shape the
    // clarification decision and the candidate a person still confirms.
    const presented = overlayPriorsOntoEvent(
      event,
      priorsByMerchant.get(identity.canonical_merchant_key) ?? [],
      sourceReceivedAt,
    );
    const presentedEvent: BillingEvent = {
      ...event,
      billing_cycle: presented.billing_cycle,
      category: presented.category,
      renewal_date: presented.renewal_date,
    };
    await supersedeResolvedClarifications(
      admin,
      userID,
      identity.canonical_merchant_key,
      lifecycle.state,
      presentedEvent.billing_cycle,
    );
    const lifecycleDraft = lifecycleClarificationDraft({
      event: presentedEvent,
      receivedAt: sourceReceivedAt,
      lifecycleState: lifecycle.state,
    });
    if (lifecycleDraft) {
      await upsertClarificationRequest(admin, userID, {
        draft: lifecycleDraft,
        merchantName: presentedEvent.merchant_name,
        merchantKey: identity.canonical_merchant_key,
        evidenceBundleID: bundleID,
        detectedEventID: savedEvent.id,
        sourceReceivedAt,
        context: {
          evidence_events: [{
            event_type: presentedEvent.event_type,
            merchant_name: presentedEvent.merchant_name,
            received_at: sourceReceivedAt,
          }],
        },
      });
      continue;
    }
    const cycleDraft = billingCycleClarificationDraft({
      event: presentedEvent,
      receivedAt: sourceReceivedAt,
      lifecycleState: lifecycle.state,
    });
    if (cycleDraft) {
      await upsertClarificationRequest(admin, userID, {
        draft: cycleDraft,
        merchantName: presentedEvent.merchant_name,
        merchantKey: identity.canonical_merchant_key,
        evidenceBundleID: bundleID,
        detectedEventID: savedEvent.id,
        sourceReceivedAt,
        context: {
          evidence_events: [{
            event_type: presentedEvent.event_type,
            merchant_name: presentedEvent.merchant_name,
            received_at: sourceReceivedAt,
          }],
        },
      });
      continue;
    }
    let action: ReturnType<typeof classifyCandidateAction> | null = null;
    if (lifecycle.state === "current") {
      await resolveStaleCancellationCandidates(
        admin,
        userID,
        identity.canonical_merchant_key,
        "Later current renewal evidence was found.",
      );
      if (lifecycle.supportingEventID !== savedEvent.id) continue;
      const suppressed = await merchantIsSuppressed(
        admin,
        userID,
        identity.canonical_merchant_key,
      );
      if (!canCreateLifecycleCandidate(lifecycle, suppressed)) {
        await resolvePendingDiscoveryCandidates(
          admin,
          userID,
          identity.canonical_merchant_key,
          "You chose not to receive discovery suggestions for this merchant.",
        );
        continue;
      }
      action = classifyCandidateAction(presentedEvent, matchedID);
    } else {
      await resolvePendingDiscoveryCandidates(
        admin,
        userID,
        identity.canonical_merchant_key,
        lifecycleResolutionReason(lifecycle.state),
      );
      const matchedStatus = typeof matched?.status === "string"
        ? matched.status
        : null;
      if (
        lifecycle.state !== "ended" ||
        lifecycle.supportingEventID !== savedEvent.id ||
        presentedEvent.event_type !== "canceled" || matchedStatus !== "active"
      ) {
        continue;
      }
      action = "cancel";
    }
    const validationIssues = semanticValidationIssues(
      presentedEvent,
      action,
      matched?.status ?? null,
    );
    const { error: validationUpdateError } = await admin
      .from("detected_billing_events")
      .update({ validation_issues: validationIssues })
      .eq("id", savedEvent.id)
      .eq("user_id", userID);
    if (validationUpdateError) throw validationUpdateError;

    const { error: candidateError } = await admin.from(
      "subscription_candidates",
    ).insert({
      user_id: userID,
      scan_run_id: runID,
      detected_event_id: savedEvent.id,
      matched_subscription_id: matchedID,
      suggested_action: action,
      merchant_name: presentedEvent.merchant_name,
      canonical_merchant_key: identity.canonical_merchant_key,
      evidence_bundle_id: bundleID,
      resolution_reason: identity.reason,
      amount: presentedEvent.amount,
      currency: presentedEvent.currency,
      billing_cycle: presentedEvent.billing_cycle,
      renewal_date: presentedEvent.renewal_date,
      category: presentedEvent.category,
      event_type: presentedEvent.event_type,
      confidence: presentedEvent.confidence,
      evidence: presentedEvent.evidence.slice(0, 280),
      validation_issues: validationIssues,
    });
    if (candidateError) throw candidateError;
    detected += 1;
  }

  const runMetrics = await addRunMetrics(admin, runID, {
    messages_scanned: providerBatch.metadata.length,
    candidate_messages: likely.length,
    events_detected: detected,
    validation_failures: validationFailures,
  });

  if (providerBatch.continuation) {
    const { error: nextJobError } = await admin.from("email_scan_jobs").upsert({
      user_id: userID,
      batch_id: (await scanRunBatchID(admin, runID)),
      scan_run_id: runID,
      connection_id: connectionID,
      page_number: pageNumber + 1,
      provider_continuation: providerBatch.continuation,
      status: "queued",
      error_message: null,
    }, { onConflict: "scan_run_id,page_number", ignoreDuplicates: true });
    if (nextJobError) throw nextJobError;
    await updateRun(admin, runID, {
      status: "running",
      stage: "queued",
      completed_at: null,
      error_message: null,
    });
    return true;
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
  await updateRun(admin, runID, {
    status: "completed",
    stage: runMetrics.events_detected > 0 ? "review_ready" : "completed",
    completed_at: now,
    error_message: null,
  });
  return false;
}

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

async function upsertClarificationRequest(
  admin: AdminClient,
  userID: string,
  input: {
    draft: InboxClarificationDraft;
    merchantName: string;
    merchantKey: string;
    evidenceBundleID: string | null;
    detectedEventID: string | null;
    sourceReceivedAt: string;
    context?: Record<string, unknown>;
  },
): Promise<void> {
  const { data: existing, error: existingError } = await admin
    .from("inbox_clarification_requests")
    .select("id")
    .eq("user_id", userID)
    .eq("canonical_merchant_key", input.merchantKey)
    .eq("kind", input.draft.kind)
    .eq("status", "open")
    .maybeSingle();
  if (existingError) throw existingError;
  if (existing) return;

  const { data: latest, error: latestError } = await admin
    .from("inbox_clarification_requests")
    .select("source_received_at")
    .eq("user_id", userID)
    .eq("canonical_merchant_key", input.merchantKey)
    .eq("kind", input.draft.kind)
    .neq("status", "open")
    .order("source_received_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (latestError) throw latestError;
  if (latest && Date.parse(String(latest.source_received_at)) >= Date.parse(input.sourceReceivedAt)) return;

  const { error } = await admin.from("inbox_clarification_requests").insert({
    user_id: userID,
    evidence_bundle_id: input.evidenceBundleID,
    detected_event_id: input.detectedEventID,
    canonical_merchant_key: input.merchantKey,
    kind: input.draft.kind,
    merchant_name: input.merchantName,
    question: input.draft.question,
    explanation: input.draft.explanation,
    choices: input.draft.choices,
    context: input.context ?? {},
    priority: input.draft.priority,
    source_received_at: input.sourceReceivedAt,
    expires_at: new Date(Date.now() + 30 * 24 * 60 * 60 * 1_000).toISOString(),
  });
  if (error && error.code !== "23505") throw error;
}

async function supersedeResolvedClarifications(
  admin: AdminClient,
  userID: string,
  merchantKey: string,
  lifecycleState: ReturnType<typeof reconcileMerchantLifecycle>["state"],
  billingCycle: BillingCycle | null,
): Promise<void> {
  const { data, error } = await admin.from("inbox_clarification_requests")
    .select("id,kind")
    .eq("user_id", userID)
    .eq("canonical_merchant_key", merchantKey)
    .eq("status", "open");
  if (error) throw error;
  const staleIDs = (data ?? []).filter((item) =>
    shouldSupersedeClarification(item.kind as InboxClarificationKind, lifecycleState, billingCycle)
  ).map((item) => item.id);
  if (staleIDs.length === 0) return;
  const { error: updateError } = await admin.from("inbox_clarification_requests")
    .update({ status: "superseded", superseded_at: new Date().toISOString() })
    .in("id", staleIDs)
    .eq("user_id", userID)
    .eq("status", "open");
  if (updateError) throw updateError;
}

async function highestPriorityClarification(
  admin: AdminClient,
  userID: string,
): Promise<Record<string, unknown> | null> {
  const now = new Date().toISOString();
  const { error: expiryError } = await admin.from("inbox_clarification_requests")
    .update({ status: "expired", resolved_at: now })
    .eq("user_id", userID)
    .eq("status", "open")
    .lt("expires_at", now);
  if (expiryError) throw expiryError;
  const { data, error } = await admin.from("inbox_clarification_requests")
    .select("id,kind,merchant_name,question,explanation,choices,context,priority,source_received_at,created_at")
    .eq("user_id", userID)
    .eq("status", "open")
    .gt("expires_at", now)
    .order("priority", { ascending: false })
    .order("source_received_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  if (!data) return null;
  return {
    id: data.id,
    kind: data.kind,
    merchant_name: data.merchant_name,
    question: data.question,
    explanation: data.explanation,
    choices: data.choices,
    evidence_events: Array.isArray((data.context as Record<string, unknown>)?.evidence_events)
      ? (data.context as Record<string, unknown>).evidence_events
      : [{ merchant_name: data.merchant_name, received_at: data.source_received_at }],
    created_at: data.created_at,
  };
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
      clarification: await highestPriorityClarification(admin, userID),
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
      "id,provider,status,stage,messages_scanned,candidate_messages,events_detected,validation_failures,error_message",
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

  const { data: candidates, error: candidatesError } = await admin
    .from("subscription_candidates")
    .select(
      "id,matched_subscription_id,suggested_action,review_status,merchant_name,amount,currency,billing_cycle,renewal_date,category,event_type,confidence,evidence,validation_issues,created_at",
    )
    .eq("user_id", userID)
    .eq("review_status", "pending")
    .order("created_at", { ascending: false });
  if (candidatesError) throw candidatesError;

  const statuses = (jobs ?? []).map((job) => job.status);
  const completed = statuses.filter((status) => status === "completed").length;
  const failed = statuses.filter((status) => status === "failed").length;
  const aggregateStatus = failed === statuses.length
    ? "failed"
    : completed + failed === statuses.length
    ? failed > 0 ? "partial" : "completed"
    : "running";
  const pendingCandidates = (candidates ?? []).filter((candidate) =>
    candidate.review_status === "pending"
  );

  return {
    scan_id: batchID,
    status: aggregateStatus,
    stage: aggregateStage(runs, aggregateStatus),
    connection_count: runs.length,
    scanned: sum(runs, "messages_scanned"),
    candidate_messages: sum(runs, "candidate_messages"),
    detected: sum(runs, "events_detected"),
    validation_failures: sum(runs, "validation_failures"),
    withheld_ambiguities: sum(runs, "withheld_ambiguities"),
    pending_count: pendingCandidates.length,
    clarification: await highestPriorityClarification(admin, userID),
    runs: runs.map((run) => {
      const job = (jobs ?? []).find((item) => item.scan_run_id === run.id);
      return {
        provider: run.provider,
        status: job?.status ?? run.status,
        stage: run.stage,
        scanned: run.messages_scanned,
        candidate_messages: run.candidate_messages,
        detected: run.events_detected,
        error: job?.error_message ?? run.error_message ?? null,
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

async function resolveClarification(
  admin: AdminClient,
  userID: string,
  body: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const requestID = requiredString(body.clarification_id, "clarification_id");
  const answer = requiredString(body.answer, "answer");
  const { data: request, error } = await admin.from("inbox_clarification_requests")
    .select("id,kind,status,canonical_merchant_key,evidence_bundle_id,detected_event_id,choices,context")
    .eq("id", requestID)
    .eq("user_id", userID)
    .maybeSingle();
  if (error) throw error;
  if (!request) throw new Error("Clarification request not found");
  const choices = Array.isArray(request.choices)
    ? request.choices as InboxClarificationChoice[]
    : [];
  if (!isClarificationAnswerAllowed(answer, choices)) {
    throw new Error("Invalid clarification answer");
  }
  if (request.status !== "open") {
    return {
      clarification_id: request.id,
      status: request.status,
      idempotent: true,
    };
  }

  const effect = answer === "not_sure"
    ? "retained_uncertain"
    : request.kind === "identity_check" && answer.startsWith("same:")
    ? "alias_recorded"
    : ["yes", "monthly", "yearly"].includes(answer)
    ? "candidate_unblocked"
    : "dismissed";
  const { data: resolutionData, error: resolutionError } = await admin.rpc(
    "resolve_inbox_clarification_request",
    {
      p_request_id: requestID,
      p_user_id: userID,
      p_answer: answer,
      p_effect: effect,
    },
  ).single();
  const resolution = resolutionData as { request_status: string; idempotent: boolean } | null;
  if (resolutionError || !resolution) throw resolutionError ?? new Error("Could not resolve clarification");
  if (resolution.idempotent) return {
    clarification_id: request.id,
    status: resolution.request_status,
    idempotent: true,
  };

  if (request.kind === "identity_check" && answer.startsWith("same:")) {
    const targetKey = answer.slice("same:".length);
    const candidateKeyValue = (request.context as Record<string, unknown>)?.candidate_keys;
    const candidateKeys = Array.isArray(candidateKeyValue)
      ? candidateKeyValue.filter((value): value is string => typeof value === "string")
      : [];
    if (candidateKeys.includes(targetKey)) {
      const { error: aliasError } = await admin.from("reviewed_merchant_aliases").upsert({
        user_id: userID,
        alias_key: request.canonical_merchant_key,
        canonical_merchant_key: targetKey,
      }, { onConflict: "user_id,alias_key" });
      if (aliasError) throw aliasError;
    }
  }
  if (request.kind === "billing_cycle_check") {
    await learnMerchantPriors(
      admin,
      userID,
      request.canonical_merchant_key,
      "corrected",
      { billing_cycle: answer },
    );
  }
  if (["yes", "monthly", "yearly"].includes(answer)) {
    await createCandidateFromClarification(admin, userID, request, answer);
  }
  return {
    clarification_id: request.id,
    status: resolution.request_status,
    idempotent: false,
  };
}

async function createCandidateFromClarification(
  admin: AdminClient,
  userID: string,
  request: Record<string, unknown>,
  answer: string,
): Promise<void> {
  const eventID = stringOrNull(request.detected_event_id);
  if (!eventID || request.kind === "identity_check") return;
  const { data: event, error: eventError } = await admin.from("detected_billing_events")
    .select("id,scan_run_id,provider,merchant_name,canonical_merchant_key,amount,currency,billing_cycle,renewal_date,category,event_type,confidence,evidence")
    .eq("id", eventID)
    .eq("user_id", userID)
    .maybeSingle();
  if (eventError) throw eventError;
  if (!event) return;
  const billingCycle = request.kind === "billing_cycle_check"
    ? answer as BillingCycle
    : event.billing_cycle as BillingCycle | null;
  if (!billingCycle || !event.amount || !event.currency) return;
  const { data: subscriptions, error: subscriptionsError } = await admin
    .from("subscriptions")
    .select("id,name,source_key,canonical_merchant_key,brand_id,status")
    .eq("user_id", userID);
  if (subscriptionsError) throw subscriptionsError;
  const clarificationEvent: BillingEvent = {
    message_id: "clarification",
    event_type: event.event_type,
    merchant_name: event.merchant_name,
    amount: Number(event.amount),
    currency: event.currency,
    billing_cycle: billingCycle,
    event_date: null,
    renewal_date: event.renewal_date,
    category: event.category,
    confidence: Number(event.confidence),
    evidence: String(event.evidence),
  };
  const matched = uniqueSubscriptionMatch(
    subscriptions ?? [],
    String(event.merchant_name),
    String(event.canonical_merchant_key),
    event.provider as Provider,
  );
  const action = classifyCandidateAction(
    clarificationEvent,
    typeof matched?.id === "string" ? matched.id : null,
  );
  const issues = semanticValidationIssues(clarificationEvent, action, matched?.status ?? null);
  if (issues.length > 0) return;
  const { error: candidateError } = await admin.from("subscription_candidates").upsert({
    user_id: userID,
    scan_run_id: event.scan_run_id,
    detected_event_id: event.id,
    matched_subscription_id: matched?.id ?? null,
    suggested_action: action,
    merchant_name: event.merchant_name,
    canonical_merchant_key: event.canonical_merchant_key,
    evidence_bundle_id: request.evidence_bundle_id ?? null,
    resolution_reason: "User clarified inbox evidence. Confirmation is still required.",
    amount: event.amount,
    currency: event.currency,
    billing_cycle: billingCycle,
    renewal_date: event.renewal_date,
    category: event.category,
    event_type: event.event_type,
    confidence: event.confidence,
    evidence: event.evidence,
    validation_issues: [],
  }, { onConflict: "detected_event_id", ignoreDuplicates: true });
  if (candidateError) throw candidateError;
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

  const metadata = await mapWithConcurrency(
    [...new Set(messageIDs)].slice(
      0,
      nextPageToken === null
        ? maximumIncrementalMessages
        : maximumMessagesPerHistoricalPage,
    ),
    6,
    (id) => fetchGmailMetadata(accessToken, id),
  );
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

async function extractBillingEvent(
  message: MailMessage,
): Promise<ReturnType<typeof validateExtractionEnvelope>> {
  const response = await fetch("https://api.deepseek.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${mustEnv("DEEPSEEK_API_KEY")}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: modelIdentifier(),
      max_tokens: 1_200,
      temperature: 0,
      response_format: { type: "json_object" },
      messages: buildExtractionMessages(message),
    }),
  });
  const payload = await response.json();
  if (!response.ok) {
    throw new Error(payload.error?.message ?? "AI extraction failed");
  }
  const text = payload.choices?.[0]?.message?.content;
  if (typeof text !== "string" || !text) {
    return {
      event: null,
      abstainReason: null,
      issues: ["ai_empty_response"],
    };
  }
  try {
    return validateExtractionEnvelope(JSON.parse(text), message.id);
  } catch {
    return { event: null, abstainReason: null, issues: ["response_not_json"] };
  }
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
  const order = ["queued", "fetching", "filtering", "extracting"];
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

function modelIdentifier(): string {
  return Deno.env.get("DEEPSEEK_MODEL") ?? "deepseek-chat";
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
