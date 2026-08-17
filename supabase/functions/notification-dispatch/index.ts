import { sendAPNS } from "../_shared/apns.ts";
import { handleOptions, json } from "../_shared/http.ts";
import { adminClient, mustEnv } from "../_shared/supabase.ts";

type OutboxRow = {
  id: string;
  user_id: string;
  batch_id: string;
  event_type: "inbox_scan_outcome" | "inbox_scan_live_update";
  outcome: "review_ready" | "no_new_discoveries" | "reconnect_required" | null;
  aggregate_count: number;
  stage: string | null;
  scanned: number;
  connection_count: number;
  route: string;
  attempts: number;
};

Deno.serve(async (request) => {
  const options = handleOptions(request);
  if (options) return options;
  if (request.method !== "POST") return json({ message: "Method not allowed" }, 405);
  if (request.headers.get("x-renewa-notification-secret") !== mustEnv("NOTIFICATION_DISPATCH_SECRET")) {
    return json({ message: "Invalid notification dispatcher secret" }, 401);
  }

  const admin = adminClient();
  try {
    const delivered = await dispatchDueEvents(admin);
    return json({ delivered });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Notification dispatch failed";
    return json({ message }, 500);
  }
});

async function dispatchDueEvents(admin: ReturnType<typeof adminClient>): Promise<number> {
  const now = new Date().toISOString();
  const { data, error } = await admin.from("notification_outbox")
    .select("id,user_id,batch_id,event_type,outcome,aggregate_count,stage,scanned,connection_count,route,attempts")
    .in("status", ["queued", "sending"])
    .lte("available_at", now)
    .or(`lease_expires_at.is.null,lease_expires_at.lt.${now}`)
    .order("created_at", { ascending: true })
    .limit(25);
  if (error) throw error;

  let delivered = 0;
  for (const row of (data ?? []) as OutboxRow[]) {
    const claimed = await claim(admin, row.id, now);
    if (!claimed) continue;
    try {
      if (row.event_type === "inbox_scan_live_update") {
        await dispatchLiveUpdate(admin, row);
      } else {
        await dispatchOutcome(admin, row);
      }
      await admin.from("notification_outbox").update({
        status: "sent",
        sent_at: new Date().toISOString(),
        lease_expires_at: null,
        last_error: null,
      }).eq("id", row.id);
      delivered += 1;
    } catch (error) {
      await retryOrFail(admin, row, error);
    }
  }
  return delivered;
}

async function claim(admin: ReturnType<typeof adminClient>, id: string, now: string): Promise<boolean> {
  const lease = new Date(Date.now() + 60_000).toISOString();
  const { data, error } = await admin.from("notification_outbox")
    .update({ status: "sending", lease_expires_at: lease })
    .eq("id", id)
    .in("status", ["queued", "sending"])
    .or(`lease_expires_at.is.null,lease_expires_at.lt.${now}`)
    .select("id")
    .maybeSingle();
  if (error) throw error;
  return data !== null;
}

async function dispatchOutcome(admin: ReturnType<typeof adminClient>, row: OutboxRow): Promise<void> {
  const { data: preference, error: preferenceError } = await admin
    .from("notification_preferences")
    .select("inbox_scan_outcomes_enabled")
    .eq("user_id", row.user_id)
    .maybeSingle();
  if (preferenceError) throw preferenceError;
  if (!preference?.inbox_scan_outcomes_enabled) return;

  const { data: installations, error } = await admin.from("notification_device_installations")
    .select("id,device_token,environment")
    .eq("user_id", row.user_id)
    .eq("is_enabled", true);
  if (error) throw error;
  const { data: liveActivities, error: liveError } = await admin.from("inbox_scan_live_activities")
    .select("installation_id")
    .eq("user_id", row.user_id)
    .eq("batch_id", row.batch_id)
    .is("ended_at", null);
  if (liveError) throw liveError;
  const liveInstallationIDs = new Set((liveActivities ?? []).map((activity) => String(activity.installation_id)));

  for (const installation of installations ?? []) {
    if (liveInstallationIDs.has(String(installation.id))) {
      await recordDelivery(admin, row.id, String(installation.id), null, "suppressed", null, "live_activity_active");
      continue;
    }
    if (await deliveryExists(admin, row.id, String(installation.id), null)) continue;
    const result = await sendAPNS({
      token: String(installation.device_token),
      environment: installation.environment === "production" ? "production" : "sandbox",
      pushType: "alert",
      payload: outcomePayload(row),
    });
    const status = result.ok ? "sent" : isInvalidToken(result.reason) ? "invalid_token" : "failed";
    await recordDelivery(admin, row.id, String(installation.id), null, status, result.apnsID, result.reason);
    if (status === "invalid_token") {
      await admin.from("notification_device_installations").update({
        is_enabled: false,
        disabled_at: new Date().toISOString(),
      }).eq("id", installation.id);
    }
    if (!result.ok && status !== "invalid_token") throw new Error(result.reason ?? `APNs returned ${result.status}`);
  }
}

async function dispatchLiveUpdate(admin: ReturnType<typeof adminClient>, row: OutboxRow): Promise<void> {
  const { data: activities, error } = await admin.from("inbox_scan_live_activities")
    .select("id,installation_id,push_token,notification_device_installations(environment)")
    .eq("user_id", row.user_id)
    .eq("batch_id", row.batch_id)
    .is("ended_at", null);
  if (error) throw error;
  for (const activity of activities ?? []) {
    const installation = activity.notification_device_installations as { environment?: string } | null;
    if (!installation?.environment || await deliveryExists(admin, row.id, null, String(activity.id))) continue;
    const finalState = row.outcome !== null;
    const result = await sendAPNS({
      token: String(activity.push_token),
      environment: installation.environment === "production" ? "production" : "sandbox",
      pushType: "liveactivity",
      topic: `${mustEnv("APNS_BUNDLE_ID")}.push-type.liveactivity`,
      payload: liveActivityPayload(row, finalState),
    });
    const status = result.ok ? "sent" : "failed";
    await recordDelivery(admin, row.id, null, String(activity.id), status, result.apnsID, result.reason);
    if (!result.ok) throw new Error(result.reason ?? `APNs returned ${result.status}`);
    await admin.from("inbox_scan_live_activities").update({
      last_stage: row.stage ?? row.outcome ?? "completed",
      last_scanned: row.scanned,
      stale_at: new Date(Date.now() + 15 * 60_000).toISOString(),
      ended_at: finalState ? new Date().toISOString() : null,
    }).eq("id", activity.id);
  }
}

function outcomePayload(row: OutboxRow): Record<string, unknown> {
  const title = row.outcome === "reconnect_required" ? "Inbox needs reconnecting" : "Inbox scan complete";
  const body = row.outcome === "review_ready"
    ? `Renewa found ${row.aggregate_count} subscription${row.aggregate_count === 1 ? "" : "s"} to review.`
    : row.outcome === "reconnect_required"
    ? "Reconnect your inbox to keep Inbox Intelligence up to date."
    : "No new subscriptions were found.";
  return {
    aps: { alert: { title, body }, sound: "default", category: "INBOX_SCAN_OUTCOME", "thread-id": "inbox-intelligence" },
    renewa_route: row.route,
    renewa_batch_id: row.batch_id,
  };
}

function liveActivityPayload(row: OutboxRow, finalState: boolean): Record<string, unknown> {
  const state = {
    stage: row.stage ?? (row.outcome === "review_ready" ? "review_ready" : "completed"),
    scanned: row.scanned,
    connectionCount: row.connection_count,
    outcome: row.outcome,
    discoveryCount: row.aggregate_count,
    route: row.route,
    batchID: row.batch_id,
  };
  return {
    aps: {
      timestamp: Math.floor(Date.now() / 1000),
      event: finalState ? "end" : "update",
      "content-state": state,
      ...(finalState ? { "dismissal-date": Math.floor(Date.now() / 1000) + 900 } : {}),
    },
  };
}

async function retryOrFail(admin: ReturnType<typeof adminClient>, row: OutboxRow, error: unknown): Promise<void> {
  const message = error instanceof Error ? error.message.slice(0, 300) : "Notification delivery failed";
  const attempts = row.attempts + 1;
  const retryable = attempts < 3;
  await admin.from("notification_outbox").update({
    status: retryable ? "queued" : "failed",
    attempts,
    available_at: new Date(Date.now() + attempts * 60_000).toISOString(),
    lease_expires_at: null,
    last_error: message,
  }).eq("id", row.id);
}

async function deliveryExists(
  admin: ReturnType<typeof adminClient>,
  outboxID: string,
  installationID: string | null,
  activityID: string | null,
): Promise<boolean> {
  let query = admin.from("notification_deliveries").select("id").eq("outbox_id", outboxID);
  query = installationID ? query.eq("installation_id", installationID) : query.eq("live_activity_id", activityID!);
  const { data, error } = await query.maybeSingle();
  if (error) throw error;
  return data !== null;
}

async function recordDelivery(
  admin: ReturnType<typeof adminClient>,
  outboxID: string,
  installationID: string | null,
  activityID: string | null,
  status: string,
  messageID: string | null,
  reason: string | null,
): Promise<void> {
  const { error } = await admin.from("notification_deliveries").upsert({
    outbox_id: outboxID,
    installation_id: installationID,
    live_activity_id: activityID,
    status,
    provider_message_id: messageID,
    provider_reason: reason,
  }, { onConflict: installationID ? "outbox_id,installation_id" : "outbox_id,live_activity_id" });
  if (error) throw error;
}

function isInvalidToken(reason: string | null): boolean {
  return reason === "BadDeviceToken" || reason === "Unregistered" || reason === "DeviceTokenNotForTopic";
}
