const taskVersion = 1;

type TriggerResponse = { id?: unknown; message?: unknown };

export type ManagedInboxTask = "scan-inbox-run" | "analyze-inbox-page";

export async function triggerManagedInboxTask(
  task: ManagedInboxTask,
  payload: Record<string, unknown>,
  options: { idempotencyKey: string; concurrencyKey: string; queueName: string; queueConcurrency: number },
): Promise<string> {
  const secret = Deno.env.get("TRIGGER_SECRET_KEY");
  if (!secret) throw new Error("Missing TRIGGER_SECRET_KEY");
  const response = await fetch(
    `https://api.trigger.dev/api/v1/tasks/${encodeURIComponent(task)}/trigger`,
    {
      method: "POST",
      headers: { Authorization: `Bearer ${secret}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        payload,
        options: {
          idempotencyKey: options.idempotencyKey,
          concurrencyKey: options.concurrencyKey,
          queue: { name: options.queueName, concurrencyLimit: options.queueConcurrency },
        },
      }),
    },
  );
  const result = await response.json().catch(() => ({})) as TriggerResponse;
  if (!response.ok || typeof result.id !== "string" || result.id.length === 0) {
    throw new Error(typeof result.message === "string" ? result.message : "Managed task could not be queued");
  }
  return result.id;
}

export function managedInboxEnabled(): boolean {
  return Deno.env.get("MANAGED_INBOX_AGENT_ENABLED") === "true";
}

export function managedPageQueue(provider: string): { name: string; concurrency: number } {
  // Trigger creates a separate queue for every concurrency key. A limit of one therefore gives
  // each user exactly one active page analysis; environment concurrency remains the global cap.
  return { name: `inbox-agent-pages-${provider}`, concurrency: 1 };
}

export function managedPagePayload(scanRunId: string, pageId: string) {
  return { version: taskVersion, scanRunId, pageId };
}

export function managedRunPayload(scanRunId: string, connectionId: string) {
  return { version: taskVersion, scanRunId, connectionId };
}

export function managedPageIdempotencyKey(scanRunId: string, pageId: string): string {
  return `inbox-page-analysis:v${taskVersion}:${scanRunId}:${pageId}`;
}

export function managedRunIdempotencyKey(scanRunId: string, connectionId: string): string {
  return `inbox-scan-run:v${taskVersion}:${scanRunId}:${connectionId}`;
}
