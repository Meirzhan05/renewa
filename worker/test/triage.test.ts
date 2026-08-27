import { test } from "node:test";
import assert from "node:assert/strict";
import { parseTriageResponse, triageInbox } from "../src/agent/triage.ts";
import type { ChatFn } from "../src/llm/client.ts";
import { mail } from "./helpers.ts";

const inbox = [
  mail({ id: "a", subject: "Your Netflix receipt", sender: "billing@netflix.com" }),
  mail({ id: "b", subject: "Weekend sale — 50% off", sender: "deals@shop.com" }),
  mail({ id: "c", subject: "Recibo de tu suscripción", sender: "facturacion@filmin.es" }),
];

// A fake that marks the shop message 'skip' and omits "c" entirely (to prove recall bias).
const fakeTriage: ChatFn = async () => ({
  content: JSON.stringify({ results: [
    { message_id: "a", decision: "look" },
    { message_id: "b", decision: "skip" },
  ] }),
  toolCalls: [],
  tokens: 5,
});

test("parseTriageResponse treats anything not explicitly 'skip' as 'look'", () => {
  const decisions = parseTriageResponse(
    JSON.stringify({ results: [{ message_id: "a", decision: "skip" }, { message_id: "b", decision: "banana" }] }),
    inbox,
  );
  assert.equal(decisions.get("a"), "skip");
  assert.equal(decisions.get("b"), "look");
});

test("triageInbox admits looks, drops explicit skips, and passes omitted ids up (recall bias)", async () => {
  const { look, skip, degraded } = await triageInbox(inbox, fakeTriage);
  const lookIds = look.map((m) => m.id).sort();
  assert.deepEqual(lookIds, ["a", "c"]); // c was omitted by the model → admitted, not dropped
  assert.deepEqual(skip.map((m) => m.id), ["b"]);
  assert.equal(degraded, false);
});

test("triageInbox degrades to recall-only on model outage — no silent loss", async () => {
  const failing: ChatFn = async () => {
    throw new Error("triage model down");
  };
  const { look, skip, degraded } = await triageInbox(inbox, failing);
  assert.equal(look.length, inbox.length); // everything admitted
  assert.equal(skip.length, 0);
  assert.equal(degraded, true);
});
