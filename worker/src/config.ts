// Worker runtime configuration, read from the environment. The LLM keys are resolved separately
// in src/llm/client.ts; this covers the queue/database side.

export type WorkerConfig = {
  databaseUrl: string;
  pollIntervalMs: number;
};

export function loadConfig(env: NodeJS.ProcessEnv = process.env): WorkerConfig {
  const databaseUrl = env.DATABASE_URL;
  if (!databaseUrl) throw new Error("DATABASE_URL is not set");
  const pollIntervalMs = Number(env.WORKER_POLL_INTERVAL_MS ?? 3_000);
  return {
    databaseUrl,
    pollIntervalMs: Number.isFinite(pollIntervalMs) && pollIntervalMs > 0 ? pollIntervalMs : 3_000,
  };
}
