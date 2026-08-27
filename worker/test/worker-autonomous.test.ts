import { test } from "node:test";
import assert from "node:assert/strict";
import { runAutonomousLoop, type AutonomousStore } from "../src/worker.ts";
import type { ScanJob } from "../src/db.ts";
import type { ProposalCandidate } from "../src/agent/types.ts";

function job(id: string): ScanJob {
  return { id, userId: "u1", provider: "gmail", accessToken: null, rawMessages: [] };
}

function proposal(key: string): ProposalCandidate {
  return {
    merchant_key: key,
    merchant_name: key,
    recurrence: "recurring",
    amount: 9.99,
    currency: "USD",
    billing_cycle: "monthly",
    category: null,
    event_type: null,
    event_date: null,
    renewal_date: null,
    confidence: 0.9,
    evidence_refs: [],
  };
}

test("runAutonomousLoop claims a job, runs the funnel, and persists its proposals", async () => {
  const finished: Array<{ jobId: string; proposals: ProposalCandidate[] }> = [];
  const failed: string[] = [];
  let handedOut = false;
  const store: AutonomousStore = {
    claimNextPendingJob: async () => {
      if (handedOut) return null;
      handedOut = true;
      return job("j1");
    },
    finishAutonomousJob: async (jobId, proposals) => {
      finished.push({ jobId, proposals });
    },
    failJob: async (jobId) => {
      failed.push(jobId);
    },
  };

  let ticks = 0;
  await runAutonomousLoop({
    store,
    scanJob: async () => [proposal("netflix")],
    pollIntervalMs: 1,
    isRunning: () => ticks++ < 1,
  });

  assert.equal(finished.length, 1);
  assert.equal(finished[0]!.jobId, "j1");
  assert.equal(finished[0]!.proposals[0]!.merchant_key, "netflix");
  assert.equal(failed.length, 0);
});

test("runAutonomousLoop records a failure when the scan throws (no infinite retry)", async () => {
  const failed: string[] = [];
  let handedOut = false;
  const store: AutonomousStore = {
    claimNextPendingJob: async () => {
      if (handedOut) return null;
      handedOut = true;
      return job("j2");
    },
    finishAutonomousJob: async () => {},
    failJob: async (jobId, error) => {
      failed.push(`${jobId}:${error}`);
    },
  };

  let ticks = 0;
  await runAutonomousLoop({
    store,
    scanJob: async () => {
      throw new Error("model down");
    },
    pollIntervalMs: 1,
    isRunning: () => ticks++ < 1,
  });

  assert.equal(failed.length, 1);
  assert.match(failed[0]!, /j2:.*model down/);
});
