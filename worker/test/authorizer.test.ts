import { test } from "node:test";
import assert from "node:assert/strict";
import { authorizeToolCall, type MerchantScope } from "../src/domain/reasoner.ts";

function scope(): MerchantScope {
  return {
    canonical_merchant_key: "anthropic",
    merchant_domains: ["anthropic.com"],
    known_message_ids: new Set(["m1", "m2"]),
  };
}

test("search_inbox requires a non-empty, bounded query", () => {
  assert.equal(authorizeToolCall("search_inbox", JSON.stringify({ query: "receipt" }), scope()).ok, true);
  assert.equal(authorizeToolCall("search_inbox", JSON.stringify({ query: "" }), scope()).ok, false);
  const long = authorizeToolCall("search_inbox", JSON.stringify({ query: "x".repeat(201) }), scope());
  assert.equal(long.ok, false);
});

test("fetch is authorized only for ids already surfaced in this scan", () => {
  assert.equal(authorizeToolCall("fetch", JSON.stringify({ message_id: "m1" }), scope()).ok, true);
  const out = authorizeToolCall("fetch", JSON.stringify({ message_id: "stranger" }), scope());
  assert.equal(out.ok, false);
  assert.equal(out.ok === false && out.reason, "out_of_scope_message");
});

test("get_more is authorized only for a domain belonging to the merchant", () => {
  const ok = authorizeToolCall("get_more", JSON.stringify({ sender: "billing@anthropic.com" }), scope());
  assert.equal(ok.ok, true);
  assert.equal(ok.ok === true && ok.request.tool === "get_more" && ok.request.sender, "anthropic.com");
  const bad = authorizeToolCall("get_more", JSON.stringify({ sender: "attacker@evil.com" }), scope());
  assert.equal(bad.ok, false);
  assert.equal(bad.ok === false && bad.reason, "sender_not_in_merchant_scope");
});

test("subdomains of a merchant domain are in scope", () => {
  const ok = authorizeToolCall("get_more", JSON.stringify({ sender: "x@mail.anthropic.com" }), scope());
  assert.equal(ok.ok, true);
});

test("unknown tools and unparseable args are rejected", () => {
  assert.equal(authorizeToolCall("delete_everything", "{}", scope()).ok, false);
  const bad = authorizeToolCall("fetch", "{not json", scope());
  assert.equal(bad.ok, false);
  assert.equal(bad.ok === false && bad.reason, "unparseable_arguments");
});
