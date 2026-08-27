import { test } from "node:test";
import assert from "node:assert/strict";
import { authorizeAgentToolCall, type AccountScope } from "../src/agent/authorizer.ts";

function scope(): AccountScope {
  return { known_message_ids: new Set(["m1", "m2"]) };
}

test("search_inbox requires a non-empty, bounded query", () => {
  assert.equal(authorizeAgentToolCall("search_inbox", JSON.stringify({ query: "receipt" }), scope()).ok, true);
  assert.equal(authorizeAgentToolCall("search_inbox", JSON.stringify({ query: "  " }), scope()).ok, false);
  assert.equal(authorizeAgentToolCall("search_inbox", JSON.stringify({ query: "x".repeat(201) }), scope()).ok, false);
});

test("fetch is authorized only for a message already surfaced this scan", () => {
  assert.equal(authorizeAgentToolCall("fetch", JSON.stringify({ message_id: "m1" }), scope()).ok, true);
  const out = authorizeAgentToolCall("fetch", JSON.stringify({ message_id: "never-seen" }), scope());
  assert.equal(out.ok, false);
  assert.equal(out.ok === false && out.reason, "unsurfaced_message");
});

test("compute_cadence rejects unsurfaced ids and oversized batches", () => {
  const ok = authorizeAgentToolCall("compute_cadence", JSON.stringify({ message_ids: ["m1", "m2"] }), scope());
  assert.equal(ok.ok, true);
  const bad = authorizeAgentToolCall("compute_cadence", JSON.stringify({ message_ids: ["m1", "ghost"] }), scope());
  assert.equal(bad.ok === false && bad.reason, "unsurfaced_message");
  const empty = authorizeAgentToolCall("compute_cadence", JSON.stringify({ message_ids: [] }), scope());
  assert.equal(empty.ok === false && empty.reason, "no_message_ids");
  const huge = authorizeAgentToolCall(
    "compute_cadence",
    JSON.stringify({ message_ids: Array.from({ length: 60 }, (_, i) => `m1`) }),
    scope(),
  );
  // All ids are surfaced (m1) but the count exceeds the cap.
  assert.equal(huge.ok === false && huge.reason, "too_many_message_ids");
});

test("reconcile reads are always authorized (read-only, whole account)", () => {
  assert.equal(authorizeAgentToolCall("list_current_subscriptions", "{}", scope()).ok, true);
  const withMerchant = authorizeAgentToolCall("list_prior_decisions", JSON.stringify({ merchant: "netflix" }), scope());
  assert.equal(withMerchant.ok === true && withMerchant.request.tool === "list_prior_decisions" && withMerchant.request.merchant, "netflix");
});

test("propose is structurally admitted (content validated downstream)", () => {
  const out = authorizeAgentToolCall("propose", JSON.stringify({ merchant_name: "Netflix" }), scope());
  assert.equal(out.ok === true && out.request.tool === "propose", true);
});

test("unknown tools and unparseable args are rejected", () => {
  assert.equal(authorizeAgentToolCall("delete_everything", "{}", scope()).ok, false);
  const bad = authorizeAgentToolCall("fetch", "{not json", scope());
  assert.equal(bad.ok === false && bad.reason, "unparseable_arguments");
});
