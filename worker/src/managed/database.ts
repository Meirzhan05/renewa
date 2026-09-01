import { MemorySaver } from "@langchain/langgraph";
import type { BaseCheckpointSaver } from "@langchain/langgraph";
import { Pool } from "pg";
import { loadManagedDatabaseConfig } from "./config.ts";

export type ManagedDatabase = {
  pool: Pool;
  checkpointer: BaseCheckpointSaver;
  close(): Promise<void>;
};

/** Creates one bounded pool for the job store, reconcile reads, and the heartbeat. */
export function createManagedDatabase(env: NodeJS.ProcessEnv = process.env): ManagedDatabase {
  const config = loadManagedDatabaseConfig(env);
  const pool = new Pool({
    connectionString: config.databaseUrl,
    max: config.poolMax,
    // The connection must survive the LLM calls a page runs between DB operations. Idle-closing it
    // on a shorter timescale than the page ceiling forces a reconnect after every model call, and a
    // reconnect under transaction-pooler pressure is what produced "timeout exceeded when trying to
    // connect". The pool is created and closed per page invocation (bounded by maxDuration), so
    // holding a connection for the page's lifetime is correct; keepAlive resists mid-call socket death.
    idleTimeoutMillis: 0,
    keepAlive: true,
    // Give a genuine reconnect (cold start, dropped socket) room to absorb brief pooler pressure
    // instead of failing on the first sub-second stall.
    connectionTimeoutMillis: 15_000,
  });
  // In-process checkpointer: a page graph runs start-to-finish in a single task invocation, so it
  // needs no cross-process persistence. MemorySaver removes the highest-frequency DB op during the
  // graph (a checkpoint write after every superstep) — the exact putWrites path that was timing out
  // — and its detached-write failure mode. The pool now serves only the job store, reconcile reads,
  // and the heartbeat. Trade-off: a re-dispatched page re-runs its Tier-2 graph from scratch.
  const checkpointer: BaseCheckpointSaver = new MemorySaver();
  return {
    pool,
    checkpointer,
    close: () => pool.end(),
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
