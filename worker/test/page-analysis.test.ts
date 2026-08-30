import { test } from "node:test";
import assert from "node:assert/strict";
import type { Pool } from "pg";
import { recordPageTriageCount } from "../src/managed/page-analysis.ts";

type Call = { text: string; params: unknown[] };

function fakePool(): { pool: Pool; calls: Call[] } {
  const calls: Call[] = [];
  const pool = {
    async query(text: string, params: unknown[]) {
      calls.push({ text, params });
      return { rows: [] };
    },
  } as unknown as Pool;
  return { pool, calls };
}

test("recordPageTriageCount writes the page's look count with an idempotent SET", async () => {
  const { pool, calls } = fakePool();
  await recordPageTriageCount(pool, "job-1", 7);
  assert.equal(calls.length, 1);
  const call = calls[0];
  assert.ok(call);
  // A plain SET (not an increment), keyed by the page/job id, so a retried page overwrites its own
  // row rather than adding to the run total.
  assert.match(call.text, /update scan_jobs set triage_look_count = \$2 where id = \$1/);
  assert.deepEqual(call.params, ["job-1", 7]);
});

test("recordPageTriageCount is idempotent: re-running a page yields the same stored value", async () => {
  const { pool, calls } = fakePool();
  await recordPageTriageCount(pool, "job-1", 5);
  await recordPageTriageCount(pool, "job-1", 5); // task retry re-executes the same page
  // Both calls SET the same row to the same value; the ledger row is not appended to.
  assert.equal(calls.length, 2);
  const [first, second] = calls;
  assert.ok(first);
  assert.ok(second);
  assert.deepEqual(first.params, ["job-1", 5]);
  assert.deepEqual(second.params, ["job-1", 5]);
});
