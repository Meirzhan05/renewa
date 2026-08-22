import { handleOptions, json } from "../_shared/http.ts";
import { sha256 } from "../_shared/crypto.ts";
import {
  clientStateMatches,
  recordInboxMonitoringEvent,
} from "../_shared/inbox-monitoring.ts";
import { adminClient, mustEnv } from "../_shared/supabase.ts";

type GooglePushPayload = {
  emailAddress?: string;
  historyId?: string;
};

type MicrosoftNotification = {
  subscriptionId?: string;
  clientState?: string;
  id?: string;
  sequenceNumber?: string;
};

Deno.serve(async (request) => {
  const validationToken = new URL(request.url).searchParams.get(
    "validationToken",
  );
  if (validationToken && request.method === "POST") {
    return new Response(validationToken, {
      headers: { "Content-Type": "text/plain; charset=utf-8" },
    });
  }
  const options = handleOptions(request);
  if (options) return options;
  if (request.method !== "POST") {
    return json({ message: "Method not allowed" }, 405);
  }

  try {
    const payload = await request.json() as Record<string, unknown>;
    if ("message" in payload) {
      await handleGmailEvent(request, payload);
      return json({ accepted: true }, 202);
    }
    if (Array.isArray(payload.value)) {
      const accepted = await handleMicrosoftEvents(payload.value);
      return json({ accepted: true, events: accepted }, 202);
    }
    return json({ message: "Unsupported provider event" }, 400);
  } catch (error) {
    const message = error instanceof Error
      ? error.message
      : "Inbox monitoring event failed";
    const status = /verification|client state|unknown|invalid/i.test(message)
      ? 401
      : 400;
    return json({ message: message.slice(0, 180) }, status);
  }
});

async function handleGmailEvent(
  request: Request,
  envelope: Record<string, unknown>,
): Promise<void> {
  await verifyGooglePushIdentity(request.headers.get("Authorization"));
  const message = envelope.message;
  if (
    !isRecord(message) || typeof message.data !== "string" ||
    typeof message.messageId !== "string"
  ) {
    throw new Error("Invalid Gmail provider event");
  }
  const decoded = decodeBase64JSON(message.data) as GooglePushPayload;
  const email = typeof decoded.emailAddress === "string"
    ? decoded.emailAddress.trim()
    : "";
  if (!email) throw new Error("Invalid Gmail provider event");

  const admin = adminClient();
  const { data: connection, error } = await admin.from("email_connections")
    .select("id,user_id")
    .eq("provider", "google")
    .ilike("email", email)
    .maybeSingle();
  if (error) throw error;
  if (!connection) throw new Error("Unknown Gmail inbox");
  const { data: watch, error: watchError } = await admin
    .from("inbox_monitoring_watches")
    .select("health")
    .eq("connection_id", connection.id)
    .maybeSingle();
  if (watchError) throw watchError;
  if (!watch || !["active", "checking", "degraded"].includes(watch.health)) {
    throw new Error("Gmail monitoring is not active");
  }
  await recordInboxMonitoringEvent(admin, {
    connectionID: connection.id,
    userID: connection.user_id,
    provider: "google",
    externalEventID: message.messageId,
    payloadHash: await sha256(`${email}|${decoded.historyId ?? ""}`),
  });
}

async function handleMicrosoftEvents(value: unknown[]): Promise<number> {
  const admin = adminClient();
  let accepted = 0;
  for (const item of value) {
    if (!isRecord(item)) continue;
    const notification = item as MicrosoftNotification;
    if (
      typeof notification.subscriptionId !== "string" ||
      typeof notification.clientState !== "string"
    ) continue;
    const { data: watch, error } = await admin.from("inbox_monitoring_watches")
      .select("connection_id,user_id,encrypted_client_state,health")
      .eq("provider", "microsoft")
      .eq("provider_resource_id", notification.subscriptionId)
      .maybeSingle();
    if (error) throw error;
    if (!watch || !["active", "checking", "degraded"].includes(watch.health)) {
      continue;
    }
    if (
      !await clientStateMatches(
        watch.encrypted_client_state,
        notification.clientState,
      )
    ) continue;
    const eventID = notification.id ?? notification.sequenceNumber;
    if (!eventID) continue;
    const created = await recordInboxMonitoringEvent(admin, {
      connectionID: watch.connection_id,
      userID: watch.user_id,
      provider: "microsoft",
      externalEventID: `${notification.subscriptionId}:${eventID}`,
      payloadHash: await sha256(
        JSON.stringify({
          subscriptionId: notification.subscriptionId,
          eventID,
        }),
      ),
    });
    if (created) accepted += 1;
  }
  return accepted;
}

async function verifyGooglePushIdentity(
  authorization: string | null,
): Promise<void> {
  const token = authorization?.startsWith("Bearer ")
    ? authorization.slice(7)
    : null;
  if (!token) throw new Error("Gmail push verification failed");
  const [encodedHeader, encodedPayload, encodedSignature] = token.split(".");
  if (!encodedHeader || !encodedPayload || !encodedSignature) {
    throw new Error("Gmail push verification failed");
  }
  const header = decodeBase64JSON(encodedHeader) as {
    kid?: string;
    alg?: string;
  };
  const claims = decodeBase64JSON(encodedPayload) as {
    aud?: string;
    iss?: string;
    email?: string;
    exp?: number;
  };
  if (header.alg !== "RS256" || typeof header.kid !== "string") {
    throw new Error("Gmail push verification failed");
  }
  if (
    !claims.aud || !claims.iss || !claims.exp ||
    claims.exp * 1_000 <= Date.now()
  ) {
    throw new Error("Gmail push verification failed");
  }
  const expectedAudience = mustEnv("GMAIL_PUBSUB_AUDIENCE");
  const expectedServiceAccount = mustEnv("GMAIL_PUBSUB_SERVICE_ACCOUNT");
  if (
    claims.aud !== expectedAudience ||
    !["accounts.google.com", "https://accounts.google.com"].includes(
      claims.iss,
    ) || claims.email !== expectedServiceAccount
  ) {
    throw new Error("Gmail push verification failed");
  }
  const keysResponse = await fetch(
    "https://www.googleapis.com/oauth2/v3/certs",
  );
  const keys = await keysResponse.json().catch(() => ({})) as {
    keys?: Array<JsonWebKey & { kid?: string }>;
  };
  const jwk = keys.keys?.find((key) => key.kid === header.kid);
  if (!keysResponse.ok || !jwk) {
    throw new Error("Gmail push verification failed");
  }
  const key = await crypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const valid = await crypto.subtle.verify(
    { name: "RSASSA-PKCS1-v1_5" },
    key,
    base64URLBytes(encodedSignature) as unknown as BufferSource,
    new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`),
  );
  if (!valid) throw new Error("Gmail push verification failed");
}

function decodeBase64JSON(value: string): unknown {
  return JSON.parse(new TextDecoder().decode(base64URLBytes(value)));
}

function base64URLBytes(value: string): Uint8Array {
  const padded = value.replaceAll("-", "+").replaceAll("_", "/") +
    "=".repeat((4 - value.length % 4) % 4);
  const decoded = atob(padded);
  return Uint8Array.from(decoded, (character) => character.charCodeAt(0));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
