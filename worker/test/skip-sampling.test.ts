import { test } from "node:test";
import assert from "node:assert/strict";
import { probeSkips, sampleSkips } from "../src/agent/skip-sampling.ts";
import { resolveBudget, DEFAULT_AGENT_BUDGET } from "../src/agent/types.ts";
import { mail } from "./helpers.ts";

const skips = [
  mail({ id: "s1", sender: "billing@filmin.es", subject: "Recibo suscripción" }),
  mail({ id: "s2", sender: "deals@shop.com", subject: "Sale" }),
  mail({ id: "s3", sender: "news@paper.com", subject: "Weekly digest" }),
];

test("sampleSkips is bounded and honors the injected RNG", () => {
  assert.equal(sampleSkips(skips, { rate: 1, rng: () => 0 }).length, 3); // rng<rate → all sampled
  assert.equal(sampleSkips(skips, { rate: 0.05, rng: () => 0.9 }).length, 0); // rng>=rate → none
  assert.equal(sampleSkips(skips, { rate: 1, cap: 2, rng: () => 0 }).length, 2); // cap wins
});

test("probeSkips reports the false-negative rate from what the agent would surface", async () => {
  // Runner pretends the Spanish receipt (a real sub) would have surfaced → a triage miss.
  const runner = async (messages: typeof skips) =>
    messages.some((m) => m.sender.includes("filmin")) ? ["filmin"] : [];
  const result = await probeSkips(skips, runner, { rate: 1, rng: () => 0 });
  assert.equal(result.sampledCount, 3);
  assert.deepEqual(result.missKeys, ["filmin"]);
  assert.ok(result.falseNegativeRate > 0 && result.falseNegativeRate <= 1);

  const empty = await probeSkips(skips, runner, { rate: 0.05, rng: () => 0.9 });
  assert.equal(empty.sampledCount, 0);
  assert.equal(empty.falseNegativeRate, 0);
});

test("resolveBudget widens for pro and defaults otherwise", () => {
  assert.equal(resolveBudget("free").maxFetches, DEFAULT_AGENT_BUDGET.maxFetches);
  assert.equal(resolveBudget(undefined).maxFetches, DEFAULT_AGENT_BUDGET.maxFetches);
  assert.ok(resolveBudget("pro").maxFetches > DEFAULT_AGENT_BUDGET.maxFetches);
});
