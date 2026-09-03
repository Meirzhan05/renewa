import { test } from "node:test";
import assert from "node:assert/strict";
import { bridgeProposalsToCandidates } from "../src/agent/candidate-bridge.ts";
import type { SqlRunner } from "../src/agent/reconcile-db.ts";
import type { ProposalCandidate } from "../src/agent/types.ts";

type Call = { text: string; params: unknown[] };

// A fake runner that routes each query by the table it touches and records every call, so tests can
// assert what the bridge wrote. detected_billing_events inserts return a synthetic id; candidate
// upserts always return a row, with `inserted` false when the merchant is in `conflictMerchants`
// (the row MERGED into an existing card rather than creating one) — the `xmax = 0` flag in the real
// statement. `senders` maps a message id to its sender so identity resolves as it does in production.
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
        return { rows: [{ id: `cand-${key}`, inserted: !conflict }] };
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

test("a proposal that MERGES into an existing card is not counted as surfaced", async () => {
  const { runner } = fakeRunner({ conflictMerchants: ["netflix"] });
  const written = await bridgeProposalsToCandidates(runner, {
    userId: "u1",
    scanRunId: "run-1",
    provider: "google",
    messagesScanned: 5,
    proposals: [proposal({ merchant_key: "netflix", merchant_name: "Netflix" })],
  });
  // The upsert returns the merged row; only a fresh insert counts as a card surfaced.
  assert.equal(written, 0);
});

test("identity comes from the evidence sender, not the model's label", async () => {
  const { runner, calls } = fakeRunner({});
  await bridgeProposalsToCandidates(runner, {
    userId: "u1",
    scanRunId: "run-1",
    provider: "google",
    messagesScanned: 5,
    // Two names the model produced for ONE vendor, each citing a different email from that vendor.
    proposals: [
      proposal({ merchant_key: "anthropic", merchant_name: "Anthropic", evidence_refs: ["m1"] }),
      proposal({
        merchant_key: "anthropic-claude-pro",
        merchant_name: "Anthropic (Claude Pro)",
        evidence_refs: ["m2"],
      }),
    ],
    messageSenders: new Map([
      ["m1", "Anthropic <no-reply@mail.anthropic.com>"],
      ["m2", "Anthropic <no-reply@mail.anthropic.com>"],
    ]),
  });

  const keys = calls
    .filter((c) => /insert into subscription_candidates/.test(c.text))
    .map((c) => String(c.params[6]));
  assert.deepEqual(keys, ["anthropic", "anthropic"], "both must resolve to one identity");
  // The display name still reflects what the model said — identity changed, presentation did not.
  const names = calls
    .filter((c) => /insert into subscription_candidates/.test(c.text))
    .map((c) => String(c.params[5]));
  assert.deepEqual(names, ["Anthropic", "Anthropic (Claude Pro)"]);
});

test("a merchant suppressed under one label is suppressed under another", async () => {
  const { runner, calls } = fakeRunner({ suppressed: ["openai"] });
  const written = await bridgeProposalsToCandidates(runner, {
    userId: "u1",
    scanRunId: "run-1",
    provider: "google",
    messagesScanned: 5,
    proposals: [proposal({
      merchant_key: "openai-chatgpt-plus",
      merchant_name: "OpenAI (ChatGPT Plus)",
      evidence_refs: ["m1"],
    })],
    messageSenders: new Map([["m1", "OpenAI <noreply@tm.openai.com>"]]),
  });
  assert.equal(written, 0);
  assert.equal(calls.some((c) => /insert into subscription_candidates/.test(c.text)), false);
});

test("without a sender lookup the proposal's own key is used", async () => {
  const { runner, calls } = fakeRunner({});
  await bridgeProposalsToCandidates(runner, {
    userId: "u1",
    scanRunId: "run-1",
    provider: "google",
    messagesScanned: 5,
    proposals: [proposal({ merchant_key: "netflix", merchant_name: "Netflix" })],
  });
  const insert = calls.find((c) => /insert into subscription_candidates/.test(c.text));
  assert.equal(String(insert?.params[6]), "netflix");
});

// canonical_merchant_key sits at the same 0-indexed position in both statements.
const KEY = 6;
const eventKeys = (calls: Call[]) =>
  calls.filter((c) => /insert into detected_billing_events/.test(c.text)).map((c) => c.params[KEY]);
const cardKeys = (calls: Call[]) =>
  calls.filter((c) => /insert into subscription_candidates/.test(c.text)).map((c) => c.params[KEY]);

// The regression these guard was not a wrong value but two rows that stopped agreeing: the bridge
// wrote identity to the card and omitted it on the event, so every merchant-scoped read in the edge
// function — the confirm gate above all — matched nothing. Assert the EQUALITY, never a literal: a
// test pinned to "anthropic" would still pass if a later change altered derivation on one path only.
test("the evidence record carries the same identity as the card it backs", async () => {
  const { runner, calls } = fakeRunner({});
  await bridgeProposalsToCandidates(runner, {
    userId: "u1",
    scanRunId: "run-1",
    provider: "google",
    messagesScanned: 5,
    proposals: [proposal({
      merchant_key: "anthropic-claude-pro",
      merchant_name: "Anthropic (Claude Pro)",
      evidence_refs: ["m1"],
    })],
    messageSenders: new Map([["m1", "Anthropic <no-reply@mail.anthropic.com>"]]),
  });

  assert.deepEqual(eventKeys(calls), cardKeys(calls), "event and card must share one identity");
  assert.equal(eventKeys(calls).length, 1);
  assert.ok(eventKeys(calls)[0], "the evidence record must not be written with a null key");
});

test("a fallback identity is written to the evidence record too, never a null", async () => {
  const { runner, calls } = fakeRunner({});
  await bridgeProposalsToCandidates(runner, {
    userId: "u1",
    scanRunId: "run-1",
    provider: "google",
    messagesScanned: 5,
    proposals: [
      // Unparseable sender: identity falls back to the proposal's own key.
      proposal({ merchant_key: "notion", merchant_name: "Notion", evidence_refs: ["m1"] }),
      // Aggregator sender: the processor billed, so identity falls back to the display name and
      // must not become "apple" on either row — that would fuse every App Store subscription.
      proposal({ merchant_key: "spotify", merchant_name: "Spotify", evidence_refs: ["m2"] }),
    ],
    messageSenders: new Map([
      ["m1", "Notion (no address)"],
      ["m2", "Apple <no_reply@email.apple.com>"],
    ]),
  });

  assert.deepEqual(eventKeys(calls), cardKeys(calls));
  assert.deepEqual(eventKeys(calls), ["notion", "spotify"]);
});

test("two labels for one sender agree on both evidence records and the merged card", async () => {
  const { runner, calls } = fakeRunner({ conflictMerchants: ["anthropic"] });
  await bridgeProposalsToCandidates(runner, {
    userId: "u1",
    scanRunId: "run-1",
    provider: "google",
    messagesScanned: 5,
    proposals: [
      proposal({ merchant_key: "anthropic", merchant_name: "Anthropic", evidence_refs: ["m1"] }),
      proposal({
        merchant_key: "anthropic-claude-pro",
        merchant_name: "Anthropic (Claude Pro)",
        evidence_refs: ["m2"],
      }),
    ],
    messageSenders: new Map([
      ["m1", "Anthropic <no-reply@mail.anthropic.com>"],
      ["m2", "Anthropic <billing@anthropic.com>"],
    ]),
  });

  // Two evidence records (one per email), one card they merge into, one identity across all three.
  assert.deepEqual(eventKeys(calls), ["anthropic", "anthropic"]);
  assert.deepEqual(cardKeys(calls), ["anthropic", "anthropic"]);
});

test("the evidence upsert repairs an unkeyed row instead of writing a second one", async () => {
  const { runner, calls } = fakeRunner({});
  await bridgeProposalsToCandidates(runner, {
    userId: "u1",
    scanRunId: "run-1",
    provider: "google",
    messagesScanned: 5,
    proposals: [proposal({ merchant_key: "netflix", merchant_name: "Netflix" })],
  });

  const insert = calls.find((c) => /insert into detected_billing_events/.test(c.text))!;
  // The fake runner cannot execute Postgres upsert semantics, so assert the statement carries the
  // repair: rows written before this column was populated gain identity on the next re-derivation,
  // which is why no backfill migration is needed.
  assert.match(insert.text, /do update set[\s\S]*canonical_merchant_key = excluded\.canonical_merchant_key/);
  // Grain is unchanged — same natural key, so repair never forks a second evidence record.
  assert.match(insert.text, /on conflict \(user_id, provider, provider_message_id, event_type\)/);
  assert.equal(eventKeys(calls).length, 1);
});
