// Shared Gmail-over-OAuth client for the dev scripts (gmail-scan, gmail-agent-trace). Read-only
// (gmail.readonly): it lists recent message ids and fetches metadata + Gmail's own snippet, and
// never writes to the inbox. The loopback OAuth flow opens a browser once and caches the token in
// out/gmail-token.json (gitignored). See scripts/gmail-scan.ts header for the one-time Google setup.

import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { fileURLToPath } from "node:url";
import { google } from "googleapis";
import type { Credentials, OAuth2Client } from "google-auth-library";
import { senderDomain, type MailMetadata } from "../src/domain/email.ts";
import type { AgentReadExecutor, AgentReadResult } from "../src/agent/agent-graph.ts";
import type { ToolMatch } from "../src/agent/types.ts";

export const GMAIL_SCOPE = "https://www.googleapis.com/auth/gmail.readonly";

export type GmailEnv = {
  clientId: string;
  clientSecret: string;
  host: string;
  port: number;
  limit: number;
  sinceDays: number;
};

export function loadGmailEnv(): GmailEnv {
  const clientId = (process.env.GMAIL_OAUTH_CLIENT_ID ?? "").trim();
  const clientSecret = (process.env.GMAIL_OAUTH_CLIENT_SECRET ?? "").trim();
  if (!clientId || !clientSecret) {
    throw new Error(
      "GMAIL_OAUTH_CLIENT_ID and GMAIL_OAUTH_CLIENT_SECRET must be set in .env. Create a 'Web " +
        "application' OAuth client in Google Cloud (see scripts/gmail-scan.ts header) and paste them in.",
    );
  }
  const port = Number(process.env.GMAIL_OAUTH_PORT ?? 42813);
  const limit = Number(process.env.GMAIL_SCAN_LIMIT ?? 150);
  const sinceDays = Number(process.env.GMAIL_SCAN_SINCE_DAYS ?? 60);
  return {
    clientId,
    clientSecret,
    host: (process.env.GMAIL_OAUTH_REDIRECT_HOST ?? "127.0.0.1").trim(),
    port: Number.isFinite(port) && port > 0 ? port : 42813,
    limit: Number.isFinite(limit) && limit > 0 ? limit : 150,
    sinceDays: Number.isFinite(sinceDays) && sinceDays > 0 ? sinceDays : 60,
  };
}

export function outDir(): string {
  const dir = fileURLToPath(new URL("../out/", import.meta.url));
  mkdirSync(dir, { recursive: true });
  return dir;
}

export function maskEmail(email: string): string {
  const [name, domain] = email.split("@");
  if (!domain || !name) return "***";
  return `${name.slice(0, 2)}***@${domain}`;
}

function redirectUri(env: GmailEnv): string {
  return `http://${env.host}:${env.port}`;
}
function tokenPath(): string {
  return `${outDir()}gmail-token.json`;
}
function readToken(): Credentials | null {
  try {
    return existsSync(tokenPath()) ? (JSON.parse(readFileSync(tokenPath(), "utf8")) as Credentials) : null;
  } catch {
    return null;
  }
}

function openBrowser(url: string): void {
  const cmd = process.platform === "darwin" ? "open" : process.platform === "win32" ? "start" : "xdg-open";
  try {
    spawn(cmd, [url], { stdio: "ignore", detached: true, shell: process.platform === "win32" }).unref();
  } catch {
    /* ignore — the URL is printed for manual open */
  }
}

function waitForCode(authUrl: string, host: string, port: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const server = createServer((req, res) => {
      const url = new URL(req.url ?? "/", `http://${host}:${port}`);
      const code = url.searchParams.get("code");
      const err = url.searchParams.get("error");
      if (err) {
        res.end(`Authorization failed: ${err}. You can close this tab.`);
        server.close();
        reject(new Error(`OAuth error: ${err}`));
      } else if (code) {
        res.writeHead(200, { "Content-Type": "text/html" });
        res.end("<html><body><h3>Renewa: authorized ✓</h3><p>You can close this tab and return to the terminal.</p></body></html>");
        server.close();
        resolve(code);
      } else {
        res.end("Waiting for authorization…");
      }
    });
    server.on("error", reject);
    server.listen(port, host, () => {
      console.log(`\nAuthorize access in your browser (it should open automatically). If not, open:\n  ${authUrl}\n`);
      openBrowser(authUrl);
    });
  });
}

/** Build an authorized OAuth2 client, reusing a cached token when present. */
export async function authorize(env: GmailEnv): Promise<OAuth2Client> {
  const oauth2 = new google.auth.OAuth2(env.clientId, env.clientSecret, redirectUri(env));
  oauth2.on("tokens", (tokens) => {
    writeFileSync(tokenPath(), JSON.stringify({ ...(readToken() ?? {}), ...tokens }, null, 2));
  });

  const cached = readToken();
  if (cached && (cached.refresh_token || cached.access_token)) {
    oauth2.setCredentials(cached);
    return oauth2;
  }

  console.log(
    `\nUsing OAuth redirect URI:  ${redirectUri(env)}\n` +
      "  → this EXACT value must be listed under 'Authorized redirect URIs' on your OAuth client.",
  );
  const authUrl = oauth2.generateAuthUrl({ access_type: "offline", prompt: "consent", scope: [GMAIL_SCOPE] });
  const code = await waitForCode(authUrl, env.host, env.port);
  const { tokens } = await oauth2.getToken(code);
  oauth2.setCredentials(tokens);
  writeFileSync(tokenPath(), JSON.stringify(tokens, null, 2));
  return oauth2;
}

function decodeEntities(s: string): string {
  return s
    .replace(/&amp;/g, "&")
    .replace(/&#39;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&nbsp;/g, " ");
}

async function mapPool<T, R>(items: T[], concurrency: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;
  async function worker(): Promise<void> {
    for (let i = next++; i < items.length; i = next++) {
      results[i] = await fn(items[i]!);
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length || 1) }, worker));
  return results;
}

/** List recent message ids, then fetch metadata + Gmail's own snippet for each. Read-only. */
export async function fetchInbox(
  auth: OAuth2Client,
  env: GmailEnv,
): Promise<{ address: string; emails: MailMetadata[] }> {
  const gmail = google.gmail({ version: "v1", auth });
  const profile = await gmail.users.getProfile({ userId: "me" });
  const address = profile.data.emailAddress ?? "me";

  const list = await gmail.users.messages.list({
    userId: "me",
    q: `newer_than:${env.sinceDays}d`,
    maxResults: Math.min(env.limit, 500),
  });
  const ids = (list.data.messages ?? []).map((m) => m.id).filter((id): id is string => Boolean(id)).slice(0, env.limit);

  const emails = await mapPool(ids, 8, async (id) => {
    const res = await gmail.users.messages.get({
      userId: "me",
      id,
      format: "metadata",
      metadataHeaders: ["Subject", "From", "Date"],
    });
    const msg = res.data;
    const headers = msg.payload?.headers ?? [];
    const header = (name: string): string =>
      headers.find((h) => (h.name ?? "").toLowerCase() === name)?.value ?? "";
    const received =
      msg.internalDate != null
        ? new Date(Number(msg.internalDate)).toISOString()
        : header("date")
          ? new Date(header("date")).toISOString()
          : new Date().toISOString();
    return {
      id: `gmail-${msg.id}`,
      subject: header("subject"),
      sender: header("from"),
      received_at: received,
      snippet: decodeEntities(msg.snippet ?? "").slice(0, 200),
    } satisfies MailMetadata;
  });

  emails.sort((a, b) => Date.parse(a.received_at) - Date.parse(b.received_at));
  return { address, emails };
}

// --- Gmail-backed read executor: fetch pulls the REAL full body on demand -----------------------

const MATCH_CAP = 12;

function toMatch(m: MailMetadata): ToolMatch {
  return { message_id: m.id, subject: m.subject, sender: m.sender, snippet: m.snippet, received_at: m.received_at };
}

type MessagePart = { mimeType?: string | null; body?: { data?: string | null } | null; parts?: MessagePart[] | null };

function decodeB64Url(data: string): string {
  return Buffer.from(data, "base64url").toString("utf8");
}
function stripHtml(html: string): string {
  return decodeEntities(html.replace(/<(style|script)[\s\S]*?<\/\1>/gi, " ").replace(/<[^>]+>/g, " "));
}
/** Walk the MIME tree for the first part of `mime` that carries data. */
function partData(payload: MessagePart | undefined, mime: string): string | null {
  const stack: MessagePart[] = payload ? [payload] : [];
  while (stack.length) {
    const p = stack.pop()!;
    if (p.mimeType === mime && p.body?.data) return p.body.data;
    if (p.parts) stack.push(...p.parts);
  }
  return null;
}
/** Prefer text/plain; fall back to stripped text/html; else a single-part text body. */
function extractGmailBody(payload: MessagePart | undefined): string {
  const plain = partData(payload, "text/plain");
  if (plain) return decodeB64Url(plain);
  const html = partData(payload, "text/html");
  if (html) return stripHtml(decodeB64Url(html));
  if (payload?.body?.data && payload.mimeType?.startsWith("text/")) {
    const text = decodeB64Url(payload.body.data);
    return payload.mimeType === "text/html" ? stripHtml(text) : text;
  }
  return "";
}
/** Sanitize + bound the body: untrusted content, so collapse whitespace, drop giant tokens, truncate. */
function sanitizeBody(text: string): string {
  return text
    .replace(/\r/g, "")
    .replace(/[ \t]+/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .replace(/\S{200,}/g, "[…]") // strip base64/tracking blobs
    .trim()
    .slice(0, 6000);
}

/**
 * A read executor backed by the live Gmail API. `search_inbox` matches within the already-triaged
 * window (metadata), while `fetch` pulls the message's FULL sanitized body from Gmail on demand —
 * which is what the `fetch` tool is meant to do. Full-body reads happen only for the few messages the
 * agent actually fetches, so it stays the expensive-but-sparing tool the budget assumes.
 */
export function createGmailReadExecutor(auth: OAuth2Client, window: MailMetadata[]): AgentReadExecutor {
  const gmail = google.gmail({ version: "v1", auth });
  const byId = new Map(window.map((m) => [m.id, m] as const));
  return async (req): Promise<AgentReadResult> => {
    if (req.tool === "fetch") {
      const meta = byId.get(req.message_id);
      if (!meta) return { tool: "fetch", message: null };
      const base = { message_id: meta.id, subject: meta.subject, sender: meta.sender, received_at: meta.received_at };
      try {
        const res = await gmail.users.messages.get({ userId: "me", id: req.message_id.replace(/^gmail-/, ""), format: "full" });
        const body = sanitizeBody(extractGmailBody(res.data.payload as MessagePart | undefined));
        return { tool: "fetch", message: { ...base, content: body || meta.snippet } };
      } catch {
        // On any fetch error, degrade to the snippet rather than failing the tool call.
        return { tool: "fetch", message: { ...base, content: meta.snippet } };
      }
    }
    const terms = req.query.toLowerCase().split(/\s+/).filter(Boolean);
    const matches = window
      .filter((m) => {
        const hay = `${m.subject}\n${m.sender}\n${m.snippet}`.toLowerCase();
        const domain = senderDomain(m.sender);
        return terms.some((t) => hay.includes(t) || domain.includes(t));
      })
      .slice(0, MATCH_CAP)
      .map(toMatch);
    return { tool: "search_inbox", matches };
  };
}
