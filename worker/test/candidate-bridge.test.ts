import { test } from "node:test";
import assert from "node:assert/strict";
import { bridgeProposalsToCandidates } from "../src/agent/candidate-bridge.ts";
import type { SqlRunner } from "../src/agent/reconcile-db.ts";
import type { ProposalCandidate } from "../src/agent/types.ts";

type Call = { text: string; params: unknown[] };

// A fake runner that routes each query by the table it touches and records every call, so tests can
// assert what the bridge wrote. detected_billing_events inserts return a synthetic id; candidate
// inserts return one row unless the merchant is in `conflictKeys` (simulating the unique conflict).
function fakeRunner(opts: {
  suppressed?: string[];
  subs?: Array<{ id: string; key: string }>;
  conflictMerchants?: string[];
}): { runner: SqlRunner; calls: Call[] } {
  const calls: Call[] = [];
  let eventSeq = 0;
  const runner: SqlRunner = {
    async query(text, params) {
      calls.push({ text, params });
      if (/from merchant_discovery_suppressions/.test(text)) {
        return { rows: (opts.suppressed ?? []).map((k) => ({ canonical_merchant_key: k })) };
      }
      if (/from subscriptions/.test(text)) {
        return { rows: (opts.subs ?? []).map((s) => ({ id: s.id, canonical_merchant_key: s.key })) };
      }
      if (/insert into detected_billing_events/.test(text)) {
        eventSeq += 1;
        return { rows: [{ id: `event-${eventSeq}` }] };
      }
      if (/insert into subscription_candidates/.test(text)) {
        const key = String(params[6]); // canonical_merchant_key position
        const conflict = (opts.conflictMerchants ?? []).includes(key);
        return { rows: conflict ? [] : [{ id: `cand-${key}` }] };
      }
      return { rows: [] };
    },
  };
  return { runner, calls };
}

function proposal(partial: Partial<ProposalCandidate> & { merchant_key: string; merchant_name: string }): ProposalCandidate {
  return {
    recurrence: "recurring",
    amount: 9.99,
    currency: "USD",
    billing_cycle: "monthly",
    category: "entertainment",
    event_type: "created",
    event_date: null,
    renewal_date: "2026-09-01",
    confidence: 0.9,
    evidence_refs: ["m1"],
    ...partial,
  };
}

test("writes a candidate per proposal without completing its shared scan run", async () => {
  const { runner, calls } = fakeRunner({});
  const written = await bridgeProposalsToCandidates(runner, {
    userId: "u1",
    scanRunId: "run-1",
    provider: "google",
    messagesScanned: 40,
    proposals: [proposal({ merchant_key: "netflix", merchant_name: "Netflix" })],
  });

  assert.equal(written, 1);
  const runUpdate = calls.find((c) => /update email_scan_runs/.test(c.text));
  assert.equal(runUpdate, undefined, "page bridge does not complete the shared run");
});

test("skips a suppressed merchant and never writes its candidate", async () => {
  const { runner, calls } = fakeRunner({ suppressed: ["spotify"] });
  const written = await bridgeProposalsToCandidates(runner, {
    userId: "u1",
    scanRunId: "run-1",
    provider: "google",
    messagesScanned: 10,
    proposals: [proposal({ merchant_key: "spotify", merchant_name: "Spotify" })],
  });

  assert.equal(written, 0);
  assert.equal(calls.some((c) => /insert into subscription_candidates/.test(c.text)), false);
  // Completion belongs to the coordinator after every page is terminal.
  const runUpdate = calls.find((c) => /update email_scan_runs/.test(c.text));
  assert.equal(runUpdate, undefined);
});

test("a matched existing subscription becomes a 'review' card, unmatched becomes 'add'", async () => {
  const { runner, calls } = fakeRunner({ subs: [{ id: "sub-9", key: "netflix" }] });
  await bridgeProposalsToCandidates(runner, {
    userId: "u1",
    scanRunId: "run-1",
    provider: "google",
    messagesScanned: 5,
    proposals: [
      proposal({ merchant_key: "netflix", merchant_name: "Netflix" }),
      proposal({ merchant_key: "notion", merchant_name: "Notion" }),
    ],
  });

  const candInserts = calls.filter((c) => /insert into subscription_candidates/.test(c.text));
  const byKey = new Map(candInserts.map((c) => [String(c.params[6]), c.params]));
  // params (0-indexed): [2]=detected_event_id [3]=matched_subscription_id [4]=suggested_action [6]=key
  assert.equal(byKey.get("netflix")?.[3], "sub-9");
  assert.equal(byKey.get("netflix")?.[4], "review");
  assert.equal(byKey.get("notion")?.[3], null);
  assert.equal(byKey.get("notion")?.[4], "add");
});

test("a duplicate candidate (detected-event conflict) is not counted", async () => {
  const { runner } = fakeRunner({ conflictMerchants: ["netflix"] });
  const written = await bridgeProposalsToCandidates(runner, {
    userId: "u1",
    scanRunId: "run-1",
    provider: "google",
    messagesScanned: 5,
    proposals: [proposal({ merchant_key: "netflix", merchant_name: "Netflix" })],
  });
  assert.equal(written, 0);
});
