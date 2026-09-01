import assert from "node:assert/strict";
import { test } from "node:test";
import type { Pool } from "pg";
import { MemorySaver } from "@langchain/langgraph";
import { createManagedDatabase, type ManagedDatabase, withManagedDatabase } from "../src/managed/database.ts";
import { loadManagedDatabaseConfig } from "../src/managed/config.ts";

const LOCAL_ENV = { MANAGED_DATABASE_URL: "postgres://user:secret@localhost:5432/postgres" };

function fakeDatabase(onClose: () => void): ManagedDatabase {
  return {
    pool: {} as Pool,
    checkpointer: new MemorySaver(),
    async close() { onClose(); },
  };
}

test("managed database closes after successful, failed, and cancelled page paths", async () => {
  for (const outcome of ["completed", "cancelled", "failed"] as const) {
    let closes = 0;
    if (outcome === "failed") {
      await assert.rejects(
        withManagedDatabase(async () => { throw new Error("analysis failed"); }, () => fakeDatabase(() => closes += 1)),
      );
    } else {
      const result = await withManagedDatabase(async () => outcome, () => fakeDatabase(() => closes += 1));
      assert.equal(result, outcome);
    }
    assert.equal(closes, 1, `${outcome} path must release the shared pool`);
  }
});

test("managed page pool survives long model calls and absorbs reconnect pressure", async () => {
  const db = createManagedDatabase(LOCAL_ENV);
  try {
    const options = (db.pool as unknown as { options: Record<string, unknown> }).options;
    // Idle-close disabled so a connection is not destroyed during an LLM call and forced to reconnect.
    assert.equal(options.idleTimeoutMillis, 0, "idle timeout must not close a connection mid-page");
    // Reconnects get a generous budget instead of failing on the first sub-second stall.
    assert.equal(options.connectionTimeoutMillis, 15_000);
    assert.equal(options.keepAlive, true);
  } finally {
    await db.close();
  }
});

test("managed page checkpointer is in-process (MemorySaver), never PostgresSaver", async () => {
  const db = createManagedDatabase(LOCAL_ENV);
  try {
    assert.ok(db.checkpointer instanceof MemorySaver, "page graph must use an in-process saver");
    assert.equal(db.checkpointer.constructor.name, "MemorySaver");
  } finally {
    await db.close();
  }
});

test("pool max defaults to 2 for heartbeat isolation and honors the env override", () => {
  assert.equal(loadManagedDatabaseConfig(LOCAL_ENV).poolMax, 2);
  assert.equal(
    loadManagedDatabaseConfig({ ...LOCAL_ENV, MANAGED_DATABASE_POOL_MAX: "3" }).poolMax,
    3,
  );
});

test("managed database rejects Supabase session-mode URLs when transaction mode is required", () => {
  assert.throws(() => loadManagedDatabaseConfig({
    MANAGED_DATABASE_URL: "postgres://postgres.ref:secret@aws-0-us-east-1.pooler.supabase.com:5432/postgres",
    MANAGED_DATABASE_REQUIRE_TRANSACTION_POOLER: "true",
  }), /transaction pooler/);
  assert.equal(loadManagedDatabaseConfig({
    MANAGED_DATABASE_URL: "postgres://postgres.ref:secret@aws-0-us-east-1.pooler.supabase.com:6543/postgres",
    MANAGED_DATABASE_REQUIRE_TRANSACTION_POOLER: "true",
  }).poolMax, 2);
});
