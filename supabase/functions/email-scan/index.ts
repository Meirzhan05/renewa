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
  candidateConfirmationIssues,
  canonicalMerchantKey,
  classifyCandidateAction,
  isLikelyBillingCandidate,
  MailMessage,
  MailMetadata,
  redactEmailAddress,
  reviewTransitionResult,
  SubscriptionCategory,
  tintForCategory,
  validateExtractionEnvelope,
} from "../_shared/email-discovery.ts";

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
  fullMessage: (metadata: MailMetadata) => Promise<MailMessage>;
};

type CandidateEdits = {
  merchant_name?: string;
  amount?: number;
  currency?: string;
  billing_cycle?: BillingCycle;
  renewal_date?: string;
  category?: SubscriptionCategory;
};

const maximumBootstrapMessages = 500;
const maximumCandidateMessages = 40;
const extractionSchemaVersion = "billing-event-v1";

Deno.serve(async (request) => {
  const options = handleOptions(request);
  if (options) return options;
  if (request.method !== "POST") {
    return json({ message: "Method not allowed" }, 405);
  }

  try {
    const user = await authenticatedUser(request);
    const admin = adminClient();
    const body = await request.json().catch(() => ({})) as Record<
      string,
      unknown
    >;
    const action = typeof body.action === "string" ? body.action : "start";

    switch (action) {
      case "start": {
        const days = boundedDays(body.days);
        const started = await startScan(admin, user.id, days);
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
        : message === "Candidate not found" ||
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
  days: number,
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

  const { data: connections, error: connectionError } = await admin
    .from("email_connections")
    .select(
      "id,user_id,provider,email,encrypted_tokens,last_scanned_at,created_at",
    )
    .eq("user_id", userID)
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
    lookback_days: days,
    scanned: 0,
    candidate_messages: 0,
    detected: 0,
    pending_count: 0,
    candidates: [],
    connections: await connectionSummaries(admin, userID),
    errors: [],
    reused: false,
  };
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
    .select("id,batch_id,scan_run_id,connection_id,attempts")
    .eq("user_id", userID)
    .eq("status", "queued")
    .lte("available_at", new Date().toISOString())
    .order("created_at", { ascending: true })
    .limit(3);
  if (batchID) query = query.eq("batch_id", batchID);
  const { data: jobs, error } = await query;
  if (error) throw error;

  for (const job of jobs ?? []) {
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
      await processConnectionJob(
        admin,
        userID,
        job.scan_run_id,
        job.connection_id,
      );
      await admin.from("email_scan_jobs").update({
        status: "completed",
        completed_at: new Date().toISOString(),
      }).eq("id", job.id);
    } catch (jobError) {
      const message = safeErrorMessage(jobError);
      const retryable = job.attempts + 1 < 3;
      await admin.from("email_connections").update({ last_error: message }).eq(
        "id",
        job.connection_id,
      ).eq("user_id", userID);
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
    }
  }
}

async function processConnectionJob(
  admin: AdminClient,
  userID: string,
  runID: string,
  connectionID: string,
): Promise<void> {
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
    ? await fetchGmailBatch(tokens.access_token, storedSync as SyncState | null)
    : await fetchMicrosoftBatch(
      tokens.access_token,
      storedSync as SyncState | null,
    );

  await updateRun(admin, runID, {
    stage: "filtering",
    messages_scanned: providerBatch.metadata.length,
  });
  const likely = providerBatch.metadata
    .filter(isLikelyBillingCandidate)
    .slice(0, maximumCandidateMessages);
  await updateRun(admin, runID, {
    candidate_messages: likely.length,
    stage: "extracting",
  });

  const { data: subscriptions, error: subscriptionsError } = await admin
    .from("subscriptions")
    .select("id,name,source_key,canonical_merchant_key,brand_id,status")
    .eq("user_id", userID);
  if (subscriptionsError) throw subscriptionsError;

  let detected = 0;
  let validationFailures = 0;
  const extractionResults = await mapWithConcurrency(
    likely,
    3,
    async (metadata) => {
      const message = await providerBatch.fullMessage(metadata);
      return await extractBillingEvent(message);
    },
  );
  for (const extraction of extractionResults) {
    if (extraction.issues.length > 0) {
      validationFailures += 1;
      continue;
    }
    if (!extraction.event) continue;

    const event = extraction.event;
    const key = canonicalMerchantKey(event.merchant_name);
    const matched = uniqueSubscriptionMatch(
      subscriptions ?? [],
      event.merchant_name,
      key,
      provider,
    );
    const matchedID = typeof matched?.id === "string" ? matched.id : null;
    const action = classifyCandidateAction(event, matchedID);
    const validationIssues = semanticValidationIssues(
      event,
      action,
      matched?.status ?? null,
    );
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
        confidence: event.confidence,
        evidence: event.evidence.slice(0, 280),
        validation_state: "valid",
        validation_issues: validationIssues,
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

    const { error: candidateError } = await admin.from(
      "subscription_candidates",
    ).insert({
      user_id: userID,
      scan_run_id: runID,
      detected_event_id: savedEvent.id,
      matched_subscription_id: matchedID,
      suggested_action: action,
      merchant_name: event.merchant_name,
      canonical_merchant_key: key,
      amount: event.amount,
      currency: event.currency,
      billing_cycle: event.billing_cycle,
      renewal_date: event.renewal_date,
      category: event.category,
      event_type: event.event_type,
      confidence: event.confidence,
      evidence: event.evidence.slice(0, 280),
      validation_issues: validationIssues,
    });
    if (candidateError) throw candidateError;
    detected += 1;
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
    stage: detected > 0 ? "review_ready" : "completed",
    events_detected: detected,
    validation_failures: validationFailures,
    completed_at: now,
    error_message: null,
  });
}

async function scanStatus(
  admin: AdminClient,
  userID: string,
  requestedBatchID: string | null,
): Promise<Record<string, unknown>> {
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
      connections: await connectionSummaries(admin, userID),
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
    .select("status,error_message")
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
    pending_count: pendingCandidates.length,
    candidates: candidates ?? [],
    connections: await connectionSummaries(admin, userID),
    errors: uniqueStrings([
      ...runs.map((run) => run.error_message),
      ...(jobs ?? []).map((job) => job.error_message),
    ]),
  };
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
    return {
      candidate_id: candidate.id,
      review_status: "ignored",
      idempotent: false,
    };
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
  const action = candidate.suggested_action === "review"
    ? candidate.event_type === "canceled"
      ? "review"
      : candidate.matched_subscription_id
      ? "update"
      : "add"
    : candidate.suggested_action;
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

async function connectionSummaries(
  admin: AdminClient,
  userID: string,
): Promise<Array<Record<string, unknown>>> {
  const { data: connections, error } = await admin
    .from("email_connections")
    .select("id,provider,email,last_scanned_at,last_error,created_at")
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

  return connections.map((connection) => {
    const sync = (syncStates ?? []).find((state) =>
      state.connection_id === connection.id
    );
    const active = (activeJobs ?? []).find((job) =>
      job.connection_id === connection.id
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
): Promise<ProviderBatch> {
  let messageIDs: string[] = [];
  let cursorValue = "";
  if (sync?.cursor_kind === "gmail_history") {
    try {
      const history = await gmailHistory(accessToken, sync.cursor_value);
      messageIDs = history.messageIDs;
      cursorValue = history.historyID;
    } catch (error) {
      if (!errorMessage(error, "").includes("cursor expired")) throw error;
      const bootstrap = await gmailBootstrap(accessToken, 30);
      messageIDs = bootstrap.messageIDs;
      cursorValue = bootstrap.historyID;
    }
  } else {
    const bootstrap = await gmailBootstrap(accessToken, 365);
    messageIDs = bootstrap.messageIDs;
    cursorValue = bootstrap.historyID;
  }

  const metadata = await mapWithConcurrency(
    [...new Set(messageIDs)].slice(0, maximumBootstrapMessages),
    6,
    (id) => fetchGmailMetadata(accessToken, id),
  );
  return {
    metadata,
    cursorKind: "gmail_history",
    cursorValue,
    fullMessage: (item) => fetchGmailFullMessage(accessToken, item),
  };
}

async function gmailBootstrap(
  accessToken: string,
  days: number,
): Promise<{ messageIDs: string[]; historyID: string }> {
  const messageIDs: string[] = [];
  let pageToken: string | null = null;
  do {
    const params = new URLSearchParams({
      maxResults: "100",
      q: `newer_than:${days}d`,
    });
    if (pageToken) params.set("pageToken", pageToken);
    const response = await providerFetch(
      `https://gmail.googleapis.com/gmail/v1/users/me/messages?${params}`,
      accessToken,
      "Gmail could not be read. Reconnect your inbox.",
    );
    const payload = await response.json();
    messageIDs.push(
      ...(payload.messages ?? []).map((message: { id: string }) => message.id),
    );
    pageToken = payload.nextPageToken ?? null;
  } while (pageToken && messageIDs.length < maximumBootstrapMessages);

  const profile = await providerFetch(
    "https://gmail.googleapis.com/gmail/v1/users/me/profile",
    accessToken,
    "Gmail profile could not be read.",
  );
  const profilePayload = await profile.json();
  return { messageIDs, historyID: String(profilePayload.historyId) };
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
  } while (pageToken && messageIDs.length < maximumBootstrapMessages);
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
): Promise<ProviderBatch> {
  try {
    return await fetchMicrosoftBatchAttempt(accessToken, sync);
  } catch (error) {
    if (
      sync?.cursor_kind === "microsoft_delta" &&
      errorMessage(error, "").includes("cursor expired")
    ) {
      return await fetchMicrosoftBatchAttempt(accessToken, null);
    }
    throw error;
  }
}

async function fetchMicrosoftBatchAttempt(
  accessToken: string,
  sync: SyncState | null,
): Promise<ProviderBatch> {
  const since = new Date(Date.now() - 365 * 86_400_000).toISOString();
  let nextURL: string;
  if (
    sync?.cursor_kind === "microsoft_delta" &&
    isMicrosoftGraphURL(sync.cursor_value)
  ) {
    nextURL = sync.cursor_value;
  } else {
    const params = new URLSearchParams({
      "$select": "id,subject,from,receivedDateTime,bodyPreview",
      "$filter": `receivedDateTime ge ${since}`,
      "$orderby": "receivedDateTime desc",
      "$top": "100",
    });
    nextURL =
      `https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messages/delta?${params}`;
  }

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
    metadata: metadata.slice(0, maximumBootstrapMessages),
    cursorKind: "microsoft_delta",
    cursorValue: deltaLink,
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
    throw new Error("AI returned no structured output");
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

function boundedDays(value: unknown): number {
  const days = typeof value === "number" && Number.isFinite(value)
    ? Math.floor(value)
    : 365;
  return Math.max(1, Math.min(days, 365));
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
