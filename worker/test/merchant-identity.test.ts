import assert from "node:assert/strict";
import { test } from "node:test";
import { registrableLabel, resolveMerchantIdentity } from "../src/domain/email.ts";

// The exact pair observed in production: one vendor, two emails, two model-chosen names. Slugging the
// name made these two identities and produced two review cards.
test("differing display names for one vendor collapse to one identity", () => {
  const a = resolveMerchantIdentity(
    "Anthropic <no-reply-M_qtrTVEfWuznus108QX0A@mail.anthropic.com>",
    "Anthropic",
  );
  const b = resolveMerchantIdentity(
    "Anthropic <no-reply-cUjRgtP_MNScZiXHvSYs_g@mail.anthropic.com>",
    "Anthropic (Claude Pro)",
  );
  assert.equal(a, b);
  assert.equal(a, "anthropic");
});

// The second observed pair, which also differs by SUBDOMAIN — no name-based heuristic catches this.
test("different subdomains of one vendor collapse to one identity", () => {
  const a = resolveMerchantIdentity("ChatGPT <noreply@email.openai.com>", "ChatGPT Plus");
  const b = resolveMerchantIdentity("OpenAI <noreply@tm.openai.com>", "OpenAI (ChatGPT Plus)");
  assert.equal(a, b);
  assert.equal(a, "openai");
});

test("distinct vendors keep distinct identities", () => {
  assert.notEqual(
    resolveMerchantIdentity("billing@anthropic.com", "Anthropic"),
    resolveMerchantIdentity("billing@openai.com", "OpenAI"),
  );
});

test("aggregator senders fall back to the display name so merchants stay separate", () => {
  const spotify = resolveMerchantIdentity("Apple <no_reply@email.apple.com>", "Spotify");
  const netflix = resolveMerchantIdentity("Apple <no_reply@email.apple.com>", "Netflix");
  assert.notEqual(spotify, netflix, "App Store receipts must not fuse into one merchant");
  assert.equal(spotify, "spotify");
  assert.equal(netflix, "netflix");
  // The processor's own domain must never become the identity.
  assert.notEqual(spotify, "apple");
});

test("payment processors fall back to the display name", () => {
  for (const sender of [
    "service@paypal.com",
    "receipts@stripe.com",
    "help@paddle.com",
    "noreply@googleplay.google.com",
  ]) {
    assert.equal(resolveMerchantIdentity(sender, "Figma"), "figma", `${sender} must not own identity`);
  }
});

test("unparseable sender falls back to the display name", () => {
  assert.equal(resolveMerchantIdentity("Some Vendor", "Notion"), "notion");
  assert.equal(resolveMerchantIdentity("", "Notion"), "notion");
});

test("no usable sender or name yields the sentinel rather than failing", () => {
  assert.equal(resolveMerchantIdentity("", ""), "unknown-merchant");
  assert.equal(resolveMerchantIdentity("garbage", "   "), "unknown-merchant");
});

test("resolution is deterministic across repeated calls", () => {
  const once = resolveMerchantIdentity("billing@mail.anthropic.com", "Anthropic");
  const twice = resolveMerchantIdentity("billing@mail.anthropic.com", "Anthropic");
  assert.equal(once, twice);
});

// A multi-part public suffix must not reduce to the suffix itself: every ".co.uk" vendor collapsing
// into the key "co" would be a silent over-merge, the failure this design forbids outright.
test("multi-part public suffixes do not collapse unrelated vendors", () => {
  assert.equal(registrableLabel("billing@vendor.co.uk"), "vendor");
  assert.equal(registrableLabel("billing@mail.shop.co.uk"), "shop");
  assert.notEqual(
    resolveMerchantIdentity("billing@alpha.co.uk", "Alpha"),
    resolveMerchantIdentity("billing@beta.co.uk", "Beta"),
  );
});

test("registrableLabel handles plain and deep domains", () => {
  assert.equal(registrableLabel("a@anthropic.com"), "anthropic");
  assert.equal(registrableLabel("a@deep.sub.example.com"), "example");
  assert.equal(registrableLabel("a@localhost"), "localhost");
  assert.equal(registrableLabel("nope"), "");
});
