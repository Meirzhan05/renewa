type APNSConfiguration = {
  bundleID: string;
  keyID: string;
  teamID: string;
  privateKey: string;
};

export type APNSResult = {
  ok: boolean;
  status: number;
  apnsID: string | null;
  reason: string | null;
};

export function apnsConfiguration(): APNSConfiguration {
  const bundleID = Deno.env.get("APNS_BUNDLE_ID")?.trim();
  const keyID = Deno.env.get("APNS_KEY_ID")?.trim();
  const teamID = Deno.env.get("APNS_TEAM_ID")?.trim();
  const privateKey = Deno.env.get("APNS_PRIVATE_KEY")?.replace(/\\n/g, "\n").trim();
  if (!bundleID || !keyID || !teamID || !privateKey) {
    throw new Error("APNs is not configured.");
  }
  return { bundleID, keyID, teamID, privateKey };
}

export async function sendAPNS(input: {
  token: string;
  environment: "sandbox" | "production";
  pushType: "alert" | "liveactivity";
  topic?: string;
  payload: Record<string, unknown>;
}): Promise<APNSResult> {
  const configuration = apnsConfiguration();
  const topic = input.topic ?? configuration.bundleID;
  const authorization = await providerAuthorization(configuration);
  const host = input.environment === "sandbox"
    ? "https://api.sandbox.push.apple.com"
    : "https://api.push.apple.com";
  const response = await fetch(`${host}/3/device/${input.token}`, {
    method: "POST",
    headers: {
      "authorization": authorization,
      "apns-topic": topic,
      "apns-push-type": input.pushType,
      "apns-priority": input.pushType === "liveactivity" ? "5" : "10",
      "content-type": "application/json",
    },
    body: JSON.stringify(input.payload),
  });
  const body = await response.json().catch(() => ({})) as { reason?: unknown };
  return {
    ok: response.ok,
    status: response.status,
    apnsID: response.headers.get("apns-id"),
    reason: typeof body.reason === "string" ? body.reason : null,
  };
}

async function providerAuthorization(configuration: APNSConfiguration): Promise<string> {
  const header = base64URL(JSON.stringify({ alg: "ES256", kid: configuration.keyID }));
  const payload = base64URL(JSON.stringify({ iss: configuration.teamID, iat: Math.floor(Date.now() / 1000) }));
  const signingInput = `${header}.${payload}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDER(configuration.privateKey),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  return `bearer ${signingInput}.${base64URL(new Uint8Array(signature))}`;
}

function pemToDER(value: string): ArrayBuffer {
  const body = value
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s/g, "");
  const binary = atob(body);
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  return bytes.buffer;
}

function base64URL(value: string | Uint8Array): string {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
