import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { keyMatches, meetsOrBeats, scoreCases, type GoldenCase, type Runner } from "../src/eval/harness.ts";
import { loadGoldenCases } from "../src/eval/harness.ts";

test("keyMatches is alias-tolerant on hyphen-prefixed refinements only", () => {
  assert.equal(keyMatches("anthropic", "anthropic"), true);
  assert.equal(keyMatches("anthropic-claude-pro", "anthropic"), true); // agent named it more specifically
  assert.equal(keyMatches("adobe", "adobe-creative-cloud"), true);
  assert.equal(keyMatches("amazon-prime", "amazon"), true);
  assert.equal(keyMatches("netflix", "netfler"), false);
  assert.equal(keyMatches("uber", "uber-eats"), true);
  assert.equal(keyMatches("uberx", "uber"), false); // not a hyphen boundary → no match
});

function goldenPath(): string {
  return fileURLToPath(new URL("../fixtures/golden-set.json", import.meta.url));
}

test("the golden-set fixture loads and has labeled cases", () => {
  const cases = loadGoldenCases(JSON.parse(readFileSync(goldenPath(), "utf8")));
  assert.ok(cases.length >= 5);
  assert.ok(cases.every((c) => c.messages.length > 0));
  assert.ok(cases.some((c) => c.expect.abstain.includes("Uber")));
});

const cases: GoldenCase[] = [
  {
    id: "sub",
    description: "a real sub",
    messages: [{ id: "n1", subject: "Netflix", sender: "billing@netflix.com", snippet: "renews $15.99 monthly", received_at: "2026-08-01T00:00:00Z" }],
    expect: { surface: [{ merchant: "Netflix", recurrence: "recurring" }], abstain: [] },
  },
  {
    id: "oneoff",
    description: "uber rides",
    messages: [{ id: "u1", subject: "trip", sender: "receipts@uber.com", snippet: "$12.40", received_at: "2026-08-02T00:00:00Z" }],
    expect: { surface: [], abstain: ["Uber"] },
  },
];

test("scoreCases computes recall and catches false positives", async () => {
  // A perfect runner: surfaces Netflix as recurring, abstains Uber.
  const perfect: Runner = async (messages) =>
    messages.some((m) => m.sender.includes("netflix"))
      ? [{ merchant_key: "netflix", recurrence: "recurring" }]
      : [];
  const good = await scoreCases(cases, perfect);
  assert.equal(good.recall, 1);
  assert.equal(good.falsePositives, 0);
  assert.equal(good.abstainClean, true);

  // A bad runner: misses Netflix and wrongly surfaces Uber.
  const bad: Runner = async (messages) =>
    messages.some((m) => m.sender.includes("uber")) ? [{ merchant_key: "uber", recurrence: "recurring" }] : [];
  const poor = await scoreCases(cases, bad);
  assert.equal(poor.recall, 0);
  assert.equal(poor.falsePositives, 1);
  assert.equal(poor.abstainClean, false);

  assert.equal(meetsOrBeats(good, poor), true);
  assert.equal(meetsOrBeats(poor, good), false);
});
