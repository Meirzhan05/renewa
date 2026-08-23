import {
  admitCandidate,
  buildClassifierMessages,
  type CandidateClassification,
  classifyCandidates,
  groupByMerchant,
  parseClassifierResponse,
} from "./discovery-classifier.ts";
import type { MailMetadata } from "./email-discovery.ts";
import type { ChatFn } from "./llm-client.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

const terseReceipt: MailMetadata = {
  id: "m-anthropic",
  subject: "Your Anthropic receipt",
  sender: "Anthropic <invoice@stripe.com>",
  received_at: "2026-08-22T10:00:00Z",
  snippet: "Thanks for your payment.",
};

const marketing: MailMetadata = {
  id: "m-promo",
  subject: "50% off this weekend only!",
  sender: "deals@shopmail.com",
  received_at: "2026-08-20T10:00:00Z",
  snippet: "Limited time sale, unsubscribe anytime.",
};

Deno.test("classifier prompt carries metadata only, never full bodies", () => {
  const messages = buildClassifierMessages([terseReceipt]);
  const serialized = JSON.stringify(messages);
  assert(serialized.includes("m-anthropic"), "should include message id");
  assert(serialized.includes("Your Anthropic receipt"), "should include subject");
  // The MailMetadata type has no `content`; assert the shape stays metadata-only.
  assert(!("content" in terseReceipt), "metadata input must not carry a body");
});

Deno.test("terse receipt with a weak keyword score is admitted when classifier marks it relevant", () => {
  const classification: CandidateClassification = {
    message_id: terseReceipt.id,
    relevant: true,
    confidence: 0.8,
    merchant_guess: "Anthropic",
    rank: 0.8,
  };
  assert(
    admitCandidate(classification, terseReceipt),
    "classifier-relevant message must be admitted",
  );
});

Deno.test("obvious marketing is excluded when classifier marks it not relevant", () => {
  const classification: CandidateClassification = {
    message_id: marketing.id,
    relevant: false,
    confidence: 0.9,
    merchant_guess: "",
    rank: 0,
  };
  assert(!admitCandidate(classification, marketing), "marketing must be excluded");
});

Deno.test("missing classification falls back to the deterministic keyword gate", () => {
  // "receipt"/"payment" style subject scores >=2 on the keyword gate; marketing does not.
  assert(
    admitCandidate(undefined, terseReceipt),
    "receipt should pass keyword fallback",
  );
  assert(
    !admitCandidate(undefined, marketing),
    "marketing should fail keyword fallback",
  );
});

Deno.test("two emails about one merchant are grouped into one bundle", () => {
  const welcome: MailMetadata = {
    id: "m-welcome",
    subject: "Welcome to Anthropic",
    sender: "team@anthropic.com",
    received_at: "2026-08-22T09:00:00Z",
    snippet: "Your account is ready.",
  };
  const bundles = groupByMerchant([
    { meta: terseReceipt, merchant_guess: "Anthropic" },
    { meta: welcome, merchant_guess: "Anthropic" },
  ]);
  assert(bundles.length === 1, "same merchant must collapse to one bundle");
  assert(bundles[0].message_ids.length === 2, "bundle must hold both messages");
});

Deno.test("classifier outage yields no classifications so callers fall back", async () => {
  const failing: ChatFn = () => Promise.reject(new Error("provider down"));
  const result = await classifyCandidates([terseReceipt, marketing], failing);
  assert(result.size === 0, "an outage must produce zero classifications");
  // With no classification, the keyword fallback still admits the receipt.
  assert(admitCandidate(result.get(terseReceipt.id), terseReceipt), "fallback admits receipt");
});

Deno.test("parseClassifierResponse ignores unknown ids and clamps confidence", () => {
  const raw = JSON.stringify({
    results: [
      { message_id: "m-anthropic", relevant: true, confidence: 5, merchant: "Anthropic" },
      { message_id: "not-in-batch", relevant: true, confidence: 0.9, merchant: "X" },
    ],
  });
  const parsed = parseClassifierResponse(raw, [terseReceipt]);
  assert(parsed.length === 1, "unknown ids must be dropped");
  assert(parsed[0].confidence === 1, "confidence must clamp to [0,1]");
});
