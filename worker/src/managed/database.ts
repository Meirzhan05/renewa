import { PostgresSaver } from "@langchain/langgraph-checkpoint-postgres";
import { Pool } from "pg";
import { loadManagedDatabaseConfig } from "./config.ts";

export type ManagedDatabase = {
  pool: Pool;
  checkpointer: PostgresSaver;
  close(): Promise<void>;
};

/** Creates one bounded pool shared by the job store and LangGraph checkpointer. */
export function createManagedDatabase(env: NodeJS.ProcessEnv = process.env): ManagedDatabase {
  const config = loadManagedDatabaseConfig(env);
  const pool = new Pool({
    connectionString: config.databaseUrl,
    max: config.poolMax,
    idleTimeoutMillis: 10_000,
    connectionTimeoutMillis: 10_000,
  });
  const checkpointer = new PostgresSaver(pool);
  return {
    pool,
    checkpointer,
    // PostgresSaver owns this exact pool, so ending it closes the only connection lifecycle.
    close: () => checkpointer.end(),
  };
}

export async function withManagedDatabase<T>(
  work: (database: ManagedDatabase) => Promise<T>,
  factory: () => ManagedDatabase = () => createManagedDatabase(),
): Promise<T> {
  const database = factory();
  try {
    return await work(database);
  } finally {
    await database.close();
  }
}

/**
 * Creates the LangGraph checkpoint tables outside of page execution. `setup()` is
 * idempotent, so the scheduler may safely invoke this after a cold deployment.
 */
export async function initializeManagedCheckpointer(
  factory: () => ManagedDatabase = () => createManagedDatabase(),
): Promise<void> {
  await withManagedDatabase(async ({ checkpointer }) => {
    await checkpointer.setup();
  }, factory);
}
