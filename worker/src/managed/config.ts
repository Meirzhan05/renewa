export type ManagedRuntimeConfig = {
  globalConcurrency: number;
  googleConcurrency: number;
  microsoftConcurrency: number;
  perUserConcurrency: number;
};

export type ManagedDatabaseConfig = {
  databaseUrl: string;
  poolMax: number;
};

function positiveInteger(name: string, value: string | undefined, fallback: number): number {
  if (value === undefined || value.length === 0) return fallback;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) {
    throw new Error(`${name} must be a positive integer`);
  }
  return parsed;
}

// The durable dispatcher admits page work fairly by user and provider before it reaches Trigger.
// Kept as a standalone reader so module-level task configuration does not need unrelated secrets.
export const DEFAULT_GLOBAL_ANALYSIS_CONCURRENCY = 4;
export const DEFAULT_PER_USER_ANALYSIS_CONCURRENCY = 1;

export function perUserAnalysisConcurrency(env: NodeJS.ProcessEnv = process.env): number {
  return positiveInteger(
    "INBOX_AGENT_PER_USER_CONCURRENCY",
    env.INBOX_AGENT_PER_USER_CONCURRENCY,
    DEFAULT_PER_USER_ANALYSIS_CONCURRENCY,
  );
}

/**
 * Managed tasks are short-lived workers. In deployed Supabase environments this must point at the
 * transaction pooler (port 6543), while local development can continue to use a local Postgres URL.
 * Keeping it separate prevents an accidental reuse of a long-lived/session-pool worker URL.
 */
export function loadManagedDatabaseConfig(env: NodeJS.ProcessEnv = process.env): ManagedDatabaseConfig {
  const databaseUrl = env.MANAGED_DATABASE_URL ?? env.DATABASE_URL;
  if (!databaseUrl) throw new Error("MANAGED_DATABASE_URL or DATABASE_URL is required for managed Inbox tasks");
  const requireTransactionPooler = env.MANAGED_DATABASE_REQUIRE_TRANSACTION_POOLER === "true";
  let parsed: URL;
  try {
    parsed = new URL(databaseUrl);
  } catch {
    throw new Error("Managed Inbox database URL must be a valid Postgres URL");
  }
  if (requireTransactionPooler && parsed.hostname.includes("pooler.supabase.com") && parsed.port !== "6543") {
    throw new Error("MANAGED_DATABASE_URL must use the Supabase transaction pooler (port 6543)");
  }
  return {
    databaseUrl,
    // A page owns exactly one database connection. Global capacity is enforced by the dispatcher.
    poolMax: positiveInteger("MANAGED_DATABASE_POOL_MAX", env.MANAGED_DATABASE_POOL_MAX, 1),
  };
}

export function loadManagedRuntimeConfig(env: NodeJS.ProcessEnv = process.env): ManagedRuntimeConfig {
  return {
    globalConcurrency: positiveInteger("INBOX_AGENT_GLOBAL_CONCURRENCY", env.INBOX_AGENT_GLOBAL_CONCURRENCY, DEFAULT_GLOBAL_ANALYSIS_CONCURRENCY),
    googleConcurrency: positiveInteger("INBOX_AGENT_GOOGLE_CONCURRENCY", env.INBOX_AGENT_GOOGLE_CONCURRENCY, DEFAULT_GLOBAL_ANALYSIS_CONCURRENCY),
    microsoftConcurrency: positiveInteger("INBOX_AGENT_MICROSOFT_CONCURRENCY", env.INBOX_AGENT_MICROSOFT_CONCURRENCY, DEFAULT_GLOBAL_ANALYSIS_CONCURRENCY),
    perUserConcurrency: perUserAnalysisConcurrency(env),
  };
}
