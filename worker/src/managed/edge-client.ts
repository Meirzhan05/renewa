import { isAnalyzeInboxPagePayload, type AnalyzeInboxPagePayload } from "./contracts.ts";
import { isScanInboxRunPayload, type ScanInboxRunPayload } from "./contracts.ts";

type ManagedPageContext = {
  cancelled?: unknown;
  execution_id?: unknown;
  access_token?: unknown;
  message?: unknown;
};

export type ClaimedManagedPage =
  | { cancelled: true }
  | { cancelled: false; executionId: string; accessToken: string };

/** Fetches the short-lived mail credential only while the task is executing. */
export async function claimManagedPageContext(
  payload: AnalyzeInboxPagePayload,
  runtimeTaskID: string,
  fetcher: typeof fetch = fetch,
): Promise<ClaimedManagedPage> {
  if (!isAnalyzeInboxPagePayload(payload)) throw new Error("Invalid managed Inbox page payload");
  const baseURL = supabaseFunctionsBaseURL();
  const response = await fetchWithTransientRetries(fetcher, `${baseURL}/functions/v1/email-scan`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: requiredPublicKey(),
      "x-renewa-managed-agent-secret": requiredEnv("MANAGED_AGENT_SHARED_SECRET"),
    },
    body: JSON.stringify({
      action: "managed_page_context",
      scan_run_id: payload.scanRunId,
      scan_job_id: payload.pageId,
      execution_id: payload.executionId,
      dispatch_token: payload.dispatchToken,
      runtime_task_id: runtimeTaskID,
    }),
  });
  const body = await response.json().catch(() => ({})) as ManagedPageContext;
  if (!response.ok) throw new Error(edgeErrorMessage(body, "Managed page context could not be loaded"));
  if (body.cancelled === true) return { cancelled: true };
  if (typeof body.execution_id !== "string" || typeof body.access_token !== "string") {
    throw new Error("Managed page context was incomplete");
  }
  return { cancelled: false, executionId: body.execution_id, accessToken: body.access_token };
}

export async function processManagedConnection(
  payload: ScanInboxRunPayload,
  fetcher: typeof fetch = fetch,
): Promise<
  { cancelled: boolean; hasNextPage: boolean; pageId: string | null; retryAfterMs: number }
> {
  if (!isScanInboxRunPayload(payload)) throw new Error("Invalid managed Inbox run payload");
  const response = await fetchWithTransientRetries(fetcher, `${supabaseFunctionsBaseURL()}/functions/v1/email-scan`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: requiredPublicKey(),
      "x-renewa-managed-agent-secret": requiredEnv("MANAGED_AGENT_SHARED_SECRET"),
    },
    body: JSON.stringify({
      action: "managed_process_connection",
      scan_run_id: payload.scanRunId,
      connection_id: payload.connectionId,
    }),
  });
  const body = await response.json().catch(() => ({})) as {
    cancelled?: unknown;
    has_next_page?: unknown;
    page_id?: unknown;
    retry_after_ms?: unknown;
    message?: unknown;
  };
  if (!response.ok) throw new Error(edgeErrorMessage(body, "Managed connection page could not be processed"));
  return {
    cancelled: body.cancelled === true,
    hasNextPage: body.has_next_page === true,
    pageId: typeof body.page_id === "string" ? body.page_id : null,
    // How long the page asked us to hold off. Absent on the ordinary path, so it reads as zero and
    // the orchestrator continues straight to the next page.
    retryAfterMs: typeof body.retry_after_ms === "number" && body.retry_after_ms > 0
      ? body.retry_after_ms
      : 0,
  };
}

function requiredEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required for managed Inbox tasks`);
  return value;
}

function requiredPublicKey(): string {
  const key = process.env.SUPABASE_PUBLISHABLE_KEY ?? process.env.SUPABASE_ANON_KEY;
  if (!key) throw new Error("SUPABASE_PUBLISHABLE_KEY is required for managed Inbox tasks");
  return key;
}

/** Accept either a project root URL or the REST endpoint used by the legacy worker. */
function supabaseFunctionsBaseURL(): string {
  return requiredEnv("SUPABASE_URL").trim().replace(/\/+$/, "").replace(/\/rest\/v1$/, "");
}

function edgeErrorMessage(body: { message?: unknown }, fallback: string): string {
  if (typeof body.message !== "string" || body.message.length === 0) return fallback;
  return body.message.slice(0, 300);
}

/**
 * The task runtime owns durable retries. This small retry only smooths short Edge gateway outages
 * before an execution record can be claimed, so a healthy page does not spend a full task attempt
 * on an intermittent 502/503/504 response.
 */
async function fetchWithTransientRetries(
  fetcher: typeof fetch,
  input: string | URL,
  init: RequestInit,
): Promise<Response> {
  let lastError: unknown;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      const response = await fetcher(input, init);
      if (![502, 503, 504].includes(response.status) || attempt === 2) return response;
    } catch (error) {
      lastError = error;
      if (attempt === 2) throw error;
    }
    await new Promise<void>((resolve) => setTimeout(resolve, 500 * (attempt + 1)));
  }
  throw lastError instanceof Error ? lastError : new Error("Managed Edge request failed");
}
