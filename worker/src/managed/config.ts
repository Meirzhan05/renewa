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

// Default number of pages a single user's scan may analyze concurrently. The orchestrator fans page
// analyses out under a per-run concurrency key, so this is the per-user bound; the global/provider
// ceilings still cap total load. Kept as a standalone reader (no TRIGGER_SECRET_KEY required) so the
// page task can set its queue limit at module load without pulling in the full runtime config.
export const DEFAULT_PER_USER_ANALYSIS_CONCURRENCY = 4;

export function perUserAnalysisConcurrency(env: NodeJS.ProcessEnv = process.env): number {
  return positiveInteger(
    "INBOX_AGENT_PER_USER_CONCURRENCY",
    env.INBOX_AGENT_PER_USER_CONCURRENCY,
    DEFAULT_PER_USER_ANALYSIS_CONCURRENCY,
  );
}

export function loadManagedRuntimeConfig(env: NodeJS.ProcessEnv = process.env): ManagedRuntimeConfig {
  const triggerSecretKey = env.TRIGGER_SECRET_KEY;
  if (!triggerSecretKey) throw new Error("TRIGGER_SECRET_KEY is required for managed Inbox tasks");
  return {
    triggerSecretKey,
    globalConcurrency: positiveInteger("INBOX_AGENT_GLOBAL_CONCURRENCY", env.INBOX_AGENT_GLOBAL_CONCURRENCY, 20),
    googleConcurrency: positiveInteger("INBOX_AGENT_GOOGLE_CONCURRENCY", env.INBOX_AGENT_GOOGLE_CONCURRENCY, 10),
    microsoftConcurrency: positiveInteger("INBOX_AGENT_MICROSOFT_CONCURRENCY", env.INBOX_AGENT_MICROSOFT_CONCURRENCY, 10),
    perUserConcurrency: perUserAnalysisConcurrency(env),
  };
}
