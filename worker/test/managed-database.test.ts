import assert from "node:assert/strict";
import { test } from "node:test";
import type { Pool } from "pg";
import { initializeManagedCheckpointer, type ManagedDatabase, withManagedDatabase } from "../src/managed/database.ts";
import { loadManagedDatabaseConfig } from "../src/managed/config.ts";

function fakeDatabase(onClose: () => void, onSetup: () => void = () => {}): ManagedDatabase {
  return {
    pool: {} as Pool,
    checkpointer: { async setup() { onSetup(); } } as ManagedDatabase["checkpointer"],
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
    assert.equal(closes, 1, `${outcome} path must release the shared checkpointer pool`);
  }
});

test("checkpoint bootstrap is idempotent infrastructure and always closes its pool", async () => {
  let setups = 0;
  let closes = 0;
  const factory = () => fakeDatabase(() => closes += 1, () => setups += 1);
  await initializeManagedCheckpointer(factory);
  await initializeManagedCheckpointer(factory);
  assert.equal(setups, 2);
  assert.equal(closes, 2);
});

test("managed database rejects Supabase session-mode URLs when transaction mode is required", () => {
  assert.throws(() => loadManagedDatabaseConfig({
    MANAGED_DATABASE_URL: "postgres://postgres.ref:secret@aws-0-us-east-1.pooler.supabase.com:5432/postgres",
    MANAGED_DATABASE_REQUIRE_TRANSACTION_POOLER: "true",
  }), /transaction pooler/);
  assert.equal(loadManagedDatabaseConfig({
    MANAGED_DATABASE_URL: "postgres://postgres.ref:secret@aws-0-us-east-1.pooler.supabase.com:6543/postgres",
    MANAGED_DATABASE_REQUIRE_TRANSACTION_POOLER: "true",
  }).poolMax, 1);
});
