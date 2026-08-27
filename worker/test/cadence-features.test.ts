import { test } from "node:test";
import assert from "node:assert/strict";
import { computeNumericCadence, extractAmount } from "../src/domain/cadence-features.ts";
import { computeCadence } from "../src/agent/tools.ts";

test("extractAmount parses common money formats", () => {
  assert.equal(extractAmount("Total $12.40"), 12.4);
  assert.equal(extractAmount("Importe 9,99 EUR"), 9.99);
  assert.equal(extractAmount("charged 12.34 USD"), 12.34);
  assert.equal(extractAmount("no money here"), null);
});

test("computeNumericCadence reports spread and interval as pure evidence (no verdict)", () => {
  const rides = [
    { subject: "trip", snippet: "Total $12.40", received_at: "2026-08-02T00:00:00Z" },
    { subject: "trip", snippet: "Total $28.10", received_at: "2026-08-05T00:00:00Z" },
    { subject: "trip", snippet: "Total $7.65", received_at: "2026-08-09T00:00:00Z" },
  ];
  const c = computeNumericCadence(rides);
  assert.equal(c.messageCount, 3);
  assert.equal(c.amountCount, 3);
  assert.ok(c.relativeSpread >= 0.25, `spread ${c.relativeSpread}`);
  assert.ok(c.medianIntervalDays !== null && c.medianIntervalDays >= 3);
  // Crucially: the module returns numbers only, no recurring/one_off verdict.
  assert.equal((c as unknown as Record<string, unknown>).recurrence, undefined);
});

test("computeCadence tool wraps the numeric features", () => {
  const res = computeCadence([{ subject: "Netflix", snippet: "$15.99 monthly", received_at: "2026-08-01T00:00:00Z" }]);
  assert.equal(res.tool, "compute_cadence");
  assert.equal(res.cadence.amountCount, 1);
  assert.equal(res.cadence.relativeSpread, 0);
});
