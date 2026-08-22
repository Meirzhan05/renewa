import { decryptJSON, encryptJSON } from "./crypto.ts";
import { Provider, refreshTokens, StoredTokens } from "./oauth.ts";
import { adminClient, mustEnv } from "./supabase.ts";
import {
  gmailWatchRequest,
  microsoftSubscriptionRequest,
  monitoringHealthForError,
  monitoringRenewalDue,
  monitoringRenewalLeadMilliseconds,
} from "./inbox-monitoring-policy.ts";

type AdminClient = ReturnType<typeof adminClient>;

type Connection = {
  id: string;
  user_id: string;
  provider: Provider;
  encrypted_tokens: string;
};

type Watch = {
  connection_id: string;
  provider: Provider;
  provider_resource_id: string | null;
  encrypted_client_state: string | null;
  health: string;
  expires_at: string | null;
};

export type MonitoringHealth =
  | "pending"
  | "active"
  | "checking"
  | "degraded"
  | "reconnect_required"
  | "disabled";

export async function provisionInboxMonitoring(
  admin: AdminClient,
  connectionID: string,
): Promise<MonitoringHealth> {
  const connection = await connectionForMonitoring(admin, connectionID);
  if (!connection) return "disabled";

  const { data: existing, error: watchError } = await admin
    .from("inbox_monitoring_watches")
    .select(
      "connection_id,provider,provider_resource_id,encrypted_client_state,health,expires_at",
    )
    .eq("connection_id", connectionID)
    .maybeSingle();
  if (watchError) throw watchError;

  try {
    const accessToken = await refreshedAccessToken(admin, connection);
    const monitored = connection.provider === "google"
      ? await provisionGmailWatch(accessToken)
      : await provisionMicrosoftSubscription(
        accessToken,
        existing as Watch | null,
      );
    const { error } = await admin.from("inbox_monitoring_watches").upsert({
      connection_id: connection.id,
      user_id: connection.user_id,
      provider: connection.provider,
      provider_resource_id: monitored.providerResourceID,
      encrypted_client_state: monitored.clientState
        ? await encryptJSON({ value: monitored.clientState })
        : null,
      expires_at: monitored.expiresAt,
      health: "active",
      last_error: null,
      last_renewal_at: new Date().toISOString(),
      last_renewal_attempt_at: new Date().toISOString(),
    }, { onConflict: "connection_id" });
    if (error) throw error;
    return "active";
  } catch (error) {
    const message = safeMonitoringError(error);
    const health: MonitoringHealth = monitoringHealthForError(message);
    const { error: persistError } = await admin.from("inbox_monitoring_watches")
      .upsert({
        connection_id: connection.id,
        user_id: connection.user_id,
        provider: connection.provider,
        health,
        last_error: message,
        last_renewal_attempt_at: new Date().toISOString(),
      }, { onConflict: "connection_id" });
    if (persistError) throw persistError;
    return health;
  }
}

export async function renewDueInboxMonitoring(
  admin: AdminClient,
  limit = 100,
): Promise<{ renewed: number; degraded: number; reconnectRequired: number }> {
  const renewalBefore = new Date(Date.now() + monitoringRenewalLeadMilliseconds)
    .toISOString();
  const { data: watches, error } = await admin
    .from("inbox_monitoring_watches")
    .select("connection_id,expires_at,health")
    .in("health", ["pending", "active", "degraded"])
    .or(`expires_at.is.null,expires_at.lte.${renewalBefore}`)
    .order("updated_at", { ascending: true })
    .limit(limit);
  if (error) throw error;

  let renewed = 0;
  let degraded = 0;
  let reconnectRequired = 0;
  for (const watch of watches ?? []) {
    if (!monitoringRenewalDue(watch.expires_at)) continue;
    const health = await provisionInboxMonitoring(admin, watch.connection_id);
    if (health === "active") renewed += 1;
    if (health === "degraded") degraded += 1;
    if (health === "reconnect_required") reconnectRequired += 1;
  }
  return { renewed, degraded, reconnectRequired };
}

export async function stopInboxMonitoring(
  admin: AdminClient,
  connectionID: string,
): Promise<void> {
  const connection = await connectionForMonitoring(admin, connectionID);
  const { data: watch, error } = await admin
    .from("inbox_monitoring_watches")
    .select(
      "connection_id,provider,provider_resource_id,encrypted_client_state,health,expires_at",
    )
    .eq("connection_id", connectionID)
    .maybeSingle();
  if (error) throw error;
  if (
    connection && watch?.provider === "microsoft" && watch.provider_resource_id
  ) {
    try {
      const accessToken = await refreshedAccessToken(admin, connection);
      await fetch(
        `https://graph.microsoft.com/v1.0/subscriptions/${
          encodeURIComponent(watch.provider_resource_id)
        }`,
        {
          method: "DELETE",
          headers: { Authorization: `Bearer ${accessToken}` },
        },
      );
    } catch {
      // Local deletion still prevents any future monitoring for this connection.
    }
  }
  const { error: deleteError } = await admin.from("inbox_monitoring_watches")
    .delete()
    .eq("connection_id", connectionID);
  if (deleteError) throw deleteError;
}

export async function clientStateMatches(
  encryptedState: string | null,
  value: string | null,
): Promise<boolean> {
  if (!encryptedState || !value) return false;
  try {
    const decrypted = await decryptJSON<{ value?: string }>(encryptedState);
    return timingSafeEqual(decrypted.value ?? "", value);
  } catch {
    return false;
  }
}

export async function recordInboxMonitoringEvent(
  admin: AdminClient,
  input: {
    connectionID: string;
    userID: string;
    provider: Provider;
    externalEventID: string;
    payloadHash: string;
  },
): Promise<boolean> {
  const { data: createdReceipts, error: receiptError } = await admin
    .from("inbox_monitoring_event_receipts")
    .upsert({
      connection_id: input.connectionID,
      user_id: input.userID,
      provider: input.provider,
      external_event_id: input.externalEventID.slice(0, 256),
      payload_hash: input.payloadHash.slice(0, 128),
    }, { onConflict: "provider,external_event_id", ignoreDuplicates: true })
    .select("id");
  if (receiptError) throw receiptError;
  if (!createdReceipts || createdReceipts.length === 0) return false;

  const { data: existing, error: workError } = await admin
    .from("inbox_monitoring_due_work")
    .select("connection_id,due_at,claimed_at")
    .eq("connection_id", input.connectionID)
    .maybeSingle();
  if (workError) throw workError;
  const dueAt = new Date(Date.now() + 2 * 60 * 1000).toISOString();
  if (!existing) {
    const { error } = await admin.from("inbox_monitoring_due_work").insert({
      connection_id: input.connectionID,
      user_id: input.userID,
      due_at: dueAt,
      event_pending: true,
      claimed_at: null,
      last_error: null,
    });
    if (error) throw error;
  } else {
    const { error } = await admin.from("inbox_monitoring_due_work").update({
      event_pending: true,
      claimed_at: existing.claimed_at ? existing.claimed_at : null,
      due_at: existing.claimed_at ? dueAt : existing.due_at,
      last_error: null,
    }).eq("connection_id", input.connectionID);
    if (error) throw error;
  }
  const { error: watchError } = await admin.from("inbox_monitoring_watches")
    .update({ last_event_at: new Date().toISOString() })
    .eq("connection_id", input.connectionID);
  if (watchError) throw watchError;
  return true;
}

async function connectionForMonitoring(
  admin: AdminClient,
  connectionID: string,
): Promise<Connection | null> {
  const { data, error } = await admin.from("email_connections")
    .select("id,user_id,provider,encrypted_tokens")
    .eq("id", connectionID)
    .maybeSingle();
  if (error) throw error;
  return data as Connection | null;
}

async function refreshedAccessToken(
  admin: AdminClient,
  connection: Connection,
): Promise<string> {
  let tokens = await decryptJSON<StoredTokens>(connection.encrypted_tokens);
  const refreshed = await refreshTokens(connection.provider, tokens);
  if (refreshed.access_token !== tokens.access_token) {
    tokens = refreshed;
    const { error } = await admin.from("email_connections").update({
      encrypted_tokens: await encryptJSON(tokens),
      token_expires_at: new Date(tokens.expires_at * 1_000).toISOString(),
    }).eq("id", connection.id);
    if (error) throw error;
  }
  return tokens.access_token;
}

async function provisionGmailWatch(
  accessToken: string,
): Promise<
  { providerResourceID: string | null; clientState: null; expiresAt: string }
> {
  const response = await fetch(
    "https://gmail.googleapis.com/gmail/v1/users/me/watch",
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(gmailWatchRequest(mustEnv("GMAIL_PUBSUB_TOPIC"))),
    },
  );
  const payload = await response.json().catch(() => ({})) as Record<
    string,
    unknown
  >;
  if (!response.ok || typeof payload.expiration !== "string") {
    throw new Error("Gmail inbox monitoring could not be enabled.");
  }
  const expiryMilliseconds = Number(payload.expiration);
  if (!Number.isFinite(expiryMilliseconds)) {
    throw new Error("Gmail returned an invalid monitoring expiration.");
  }
  return {
    providerResourceID: typeof payload.historyId === "string"
      ? payload.historyId
      : null,
    clientState: null,
    expiresAt: new Date(expiryMilliseconds).toISOString(),
  };
}

async function provisionMicrosoftSubscription(
  accessToken: string,
  existing: Watch | null,
): Promise<
  { providerResourceID: string; clientState: string; expiresAt: string }
> {
  const clientState = await existingClientState(existing) ??
    randomClientState();
  const notificationURL = Deno.env.get("INBOX_MONITORING_WEBHOOK_URL") ??
    `${mustEnv("SUPABASE_URL")}/functions/v1/inbox-monitor`;
  const response = await fetch(
    "https://graph.microsoft.com/v1.0/subscriptions",
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(
        microsoftSubscriptionRequest(notificationURL, clientState),
      ),
    },
  );
  const payload = await response.json().catch(() => ({})) as Record<
    string,
    unknown
  >;
  if (
    !response.ok || typeof payload.id !== "string" ||
    typeof payload.expirationDateTime !== "string"
  ) {
    throw new Error("Microsoft inbox monitoring could not be enabled.");
  }
  if (
    existing?.provider_resource_id &&
    existing.provider_resource_id !== payload.id
  ) {
    await fetch(
      `https://graph.microsoft.com/v1.0/subscriptions/${
        encodeURIComponent(existing.provider_resource_id)
      }`,
      { method: "DELETE", headers: { Authorization: `Bearer ${accessToken}` } },
    );
  }
  return {
    providerResourceID: payload.id,
    clientState,
    expiresAt: payload.expirationDateTime,
  };
}

async function existingClientState(
  existing: Watch | null,
): Promise<string | null> {
  if (!existing?.encrypted_client_state) return null;
  try {
    return (await decryptJSON<{ value?: string }>(
      existing.encrypted_client_state,
    )).value ?? null;
  } catch {
    return null;
  }
}

function randomClientState(): string {
  return crypto.randomUUID().replaceAll("-", "") +
    crypto.randomUUID().replaceAll("-", "");
}

function safeMonitoringError(error: unknown): string {
  const message = error instanceof Error
    ? error.message
    : "Inbox monitoring needs attention.";
  return message.slice(0, 280);
}

function timingSafeEqual(left: string, right: string): boolean {
  const leftBytes = new TextEncoder().encode(left);
  const rightBytes = new TextEncoder().encode(right);
  let mismatch = leftBytes.length ^ rightBytes.length;
  const length = Math.max(leftBytes.length, rightBytes.length);
  for (let index = 0; index < length; index += 1) {
    mismatch |= (leftBytes[index] ?? 0) ^ (rightBytes[index] ?? 0);
  }
  return mismatch === 0;
}
