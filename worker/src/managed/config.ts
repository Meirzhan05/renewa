export type ManagedRuntimeConfig = {
  triggerSecretKey: string;
  globalConcurrency: number;
  googleConcurrency: number;
  microsoftConcurrency: number;
  perUserConcurrency: number;
};

function positiveInteger(name: string, value: string | undefined, fallback: number): number {
  if (value === undefined || value.length === 0) return fallback;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) {
    throw new Error(`${name} must be a positive integer`);
  }
  return parsed;
}

export function loadManagedRuntimeConfig(env: NodeJS.ProcessEnv = process.env): ManagedRuntimeConfig {
  const triggerSecretKey = env.TRIGGER_SECRET_KEY;
  if (!triggerSecretKey) throw new Error("TRIGGER_SECRET_KEY is required for managed Inbox tasks");
  return {
    triggerSecretKey,
    globalConcurrency: positiveInteger("INBOX_AGENT_GLOBAL_CONCURRENCY", env.INBOX_AGENT_GLOBAL_CONCURRENCY, 20),
    googleConcurrency: positiveInteger("INBOX_AGENT_GOOGLE_CONCURRENCY", env.INBOX_AGENT_GOOGLE_CONCURRENCY, 10),
    microsoftConcurrency: positiveInteger("INBOX_AGENT_MICROSOFT_CONCURRENCY", env.INBOX_AGENT_MICROSOFT_CONCURRENCY, 10),
    perUserConcurrency: positiveInteger("INBOX_AGENT_PER_USER_CONCURRENCY", env.INBOX_AGENT_PER_USER_CONCURRENCY, 1),
  };
}
