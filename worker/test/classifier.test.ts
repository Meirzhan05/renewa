import { test } from "node:test";
import assert from "node:assert/strict";
import {
  admitCandidate,
  classifyCandidates,
  groupByMerchant,
  parseClassifierResponse,
  RELEVANCE_ADMIT_THRESHOLD,
} from "../src/domain/classifier.ts";
import { mail } from "./helpers.ts";
import type { ChatFn } from "../src/llm/client.ts";

test("parseClassifierResponse keeps only known ids and clamps confidence", () => {
  const batch = [mail({ id: "a" }), mail({ id: "b" })];
  const rows = parseClassifierResponse(
    JSON.stringify({
      results: [
        { message_id: "a", relevant: true, confidence: 1.7, merchant: "Netflix" },
        { message_id: "ghost", relevant: true, confidence: 0.9, merchant: "X" },
      ],
    }),
    batch,
  );
  assert.equal(rows.length, 1);
  assert.equal(rows[0]!.message_id, "a");
  assert.equal(rows[0]!.confidence, 1); // clamped into 0..1
});

test("admitCandidate: classifier governs when present", () => {
  const meta = mail({ id: "a", subject: "hi" });
  assert.equal(
    admitCandidate({ message_id: "a", relevant: true, confidence: 0.9, merchant_guess: "X", rank: 0.9 }, meta),
    true,
  );
  assert.equal(
    admitCandidate(
      { message_id: "a", relevant: true, confidence: RELEVANCE_ADMIT_THRESHOLD - 0.01, merchant_guess: "X", rank: 0 },
      meta,
    ),
    false,
  );
});

test("admitCandidate: falls back to keyword gate when classification absent", () => {
  const billing = mail({ id: "a", subject: "Your receipt", snippet: "payment of $9.99 USD" });
  const marketing = mail({ id: "b", subject: "Big sale — save up to 50%", snippet: "limited time offer" });
  assert.equal(admitCandidate(undefined, billing), true);
  assert.equal(admitCandidate(undefined, marketing), false);
});

test("groupByMerchant buckets by canonical merchant key", () => {
  const bundles = groupByMerchant([
    { meta: mail({ id: "a", sender: "billing@netflix.com" }), merchant_guess: "Netflix" },
    { meta: mail({ id: "b", sender: "receipts@netflix.com" }), merchant_guess: "Netflix" },
    { meta: mail({ id: "c", sender: "no-reply@uber.com" }), merchant_guess: "Uber" },
  ]);
  assert.equal(bundles.length, 2);
  const netflix = bundles.find((b) => b.canonical_merchant_key === "netflix");
  assert.deepEqual(netflix!.message_ids.sort(), ["a", "b"]);
});

test("classifyCandidates degrades to empty map when the model errors", async () => {
  const throwing: ChatFn = async () => {
    throw new Error("classifier down");
  };
  const map = await classifyCandidates([mail({ id: "a" })], throwing);
  assert.equal(map.size, 0); // callers then fall back to the keyword gate
});
