import { test } from "node:test";
import assert from "node:assert/strict";
import {
  decodeEntities,
  extractGmailBody,
  sanitizeBody,
  stripHtml,
  type MessagePart,
} from "../src/domain/gmail-body.ts";

const b64 = (s: string): string => Buffer.from(s, "utf8").toString("base64url");

test("extractGmailBody prefers text/plain over text/html", () => {
  const payload: MessagePart = {
    mimeType: "multipart/alternative",
    parts: [
      { mimeType: "text/plain", body: { data: b64("Receipt from Anthropic — $20.00 monthly") } },
      { mimeType: "text/html", body: { data: b64("<p>ignored html</p>") } },
    ],
  };
  assert.equal(extractGmailBody(payload), "Receipt from Anthropic — $20.00 monthly");
});

test("extractGmailBody falls back to stripped text/html when no plain part", () => {
  const payload: MessagePart = {
    mimeType: "multipart/alternative",
    parts: [
      { mimeType: "text/html", body: { data: b64("<style>x{}</style><b>Your receipt</b> <a>$20</a>") } },
    ],
  };
  const body = extractGmailBody(payload);
  assert.match(body, /Your receipt/);
  assert.match(body, /\$20/);
  assert.doesNotMatch(body, /<b>|<style>|x\{\}/);
});

test("extractGmailBody reads a single text/plain body node", () => {
  const payload: MessagePart = { mimeType: "text/plain", body: { data: b64("plain single part") } };
  assert.equal(extractGmailBody(payload), "plain single part");
});

test("extractGmailBody returns empty string for an empty/absent payload", () => {
  assert.equal(extractGmailBody(undefined), "");
  assert.equal(extractGmailBody({ mimeType: "multipart/mixed", parts: [] }), "");
});

test("stripHtml drops script/style blocks and decodes entities", () => {
  assert.equal(stripHtml("<script>bad()</script>Total&nbsp;&amp;more"), " Total &more");
});

test("decodeEntities handles the common entities", () => {
  assert.equal(decodeEntities("a &lt;b&gt; &quot;c&quot; &#39;d&#39;"), 'a <b> "c" \'d\'');
});

test("sanitizeBody collapses whitespace, strips base64 blobs, and caps length", () => {
  const blob = "A".repeat(500);
  const cleaned = sanitizeBody(`a\r\nb   c\t\td ${blob}`);
  assert.equal(cleaned, "a\nb c d […]");
  assert.doesNotMatch(cleaned, /A{200}/);
  // 3+ consecutive newlines collapse to a blank line.
  assert.equal(sanitizeBody("x\n\n\n\n\ny"), "x\n\ny");
  assert.ok(sanitizeBody("x".repeat(10_000)).length <= 6000);
});
