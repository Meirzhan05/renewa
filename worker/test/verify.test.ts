import { test } from "node:test";
import assert from "node:assert/strict";
import { applyVerification, parseVerifyVerdict, verifyAssessment } from "../src/domain/verify.ts";
import { parseAssessment } from "../src/domain/reasoner.ts";
import type { ChatFn } from "../src/llm/client.ts";

function complete() {
  return parseAssessment(
    JSON.stringify({ existence: "high", amount: 15.99, currency: "USD", billing_cycle: "monthly", confidence: 0.9 }),
    "netflix",
    "Netflix",
  );
}

test("applyVerification strips ungrounded fields and recomputes completeness", () => {
  const next = applyVerification(complete(), { existence_supported: true, grounded_fields: ["amount", "currency"] });
  assert.equal(next.billing_cycle, null); // not grounded → stripped
  assert.equal(next.completeness, "incomplete");
  assert.deepEqual(next.missing_fields, ["billing_cycle"]);
});

test("applyVerification downgrades existence when unsupported", () => {
  const next = applyVerification(complete(), { existence_supported: false, grounded_fields: [] });
  assert.equal(next.existence, "low");
  assert.equal(next.abstain_reason, "existence_unverified");
});

test("parseVerifyVerdict tolerates junk", () => {
  assert.equal(parseVerifyVerdict("nope"), null);
});

test("verifyAssessment passes through unchanged when the verifier errors", async () => {
  const throwing: ChatFn = async () => {
    throw new Error("verifier down");
  };
  const input = complete();
  const out = await verifyAssessment(input, ["evidence"], throwing);
  assert.deepEqual(out, input); // graceful degradation, not a dropped subscription
});

test("verifyAssessment skips the call entirely for low-existence assessments", async () => {
  let called = false;
  const chat: ChatFn = async () => {
    called = true;
    return { content: "{}", toolCalls: [], tokens: 0 };
  };
  const low = parseAssessment(JSON.stringify({ existence: "low" }), "x", "X");
  await verifyAssessment(low, ["e"], chat);
  assert.equal(called, false);
});
