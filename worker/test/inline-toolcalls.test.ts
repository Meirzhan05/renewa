import { test } from "node:test";
import assert from "node:assert/strict";
import { parseInlineToolCalls, parseChatPayload } from "../src/llm/client.ts";

// The exact shape DeepSeek leaked into `content` during the real Gmail smoke test: its tool calls
// came back as `<｜｜DSML｜｜invoke …>` markup instead of structured `tool_calls`, which made the agent
// terminate before it could `propose`. These tests lock in the recovery.
const DSML_CADENCE = `Let me compute the cadence.
<｜｜DSML｜｜tool_calls>
<｜｜DSML｜｜invoke name="compute_cadence">
<｜｜DSML｜｜parameter name="merchant" string="true">Anthropic</｜｜DSML｜｜parameter>
</｜｜DSML｜｜invoke>
<｜｜DSML｜｜invoke name="compute_cadence">
<｜｜DSML｜｜parameter name="merchant" string="true">OpenAI</｜｜DSML｜｜parameter>
</｜｜DSML｜｜invoke>
</｜｜DSML｜｜tool_calls>`;

test("recovers leaked DSML tool calls from content", () => {
  const calls = parseInlineToolCalls(DSML_CADENCE);
  assert.equal(calls.length, 2);
  assert.equal(calls[0]!.name, "compute_cadence");
  assert.deepEqual(JSON.parse(calls[0]!.arguments), { merchant: "Anthropic" });
  assert.equal(calls[1]!.name, "compute_cadence");
  assert.deepEqual(JSON.parse(calls[1]!.arguments), { merchant: "OpenAI" });
});

test("recovers a leaked propose call with typed + array params", () => {
  const dsmlPropose = `<｜｜DSML｜｜invoke name="propose">
<｜｜DSML｜｜parameter name="merchant_name" string="true">Anthropic</｜｜DSML｜｜parameter>
<｜｜DSML｜｜parameter name="recurrence" string="true">recurring</｜｜DSML｜｜parameter>
<｜｜DSML｜｜parameter name="amount">20</｜｜DSML｜｜parameter>
<｜｜DSML｜｜parameter name="evidence_refs">["gmail-1a02a73212e8e7c3"]</｜｜DSML｜｜parameter>
</｜｜DSML｜｜invoke>`;
  const calls = parseInlineToolCalls(dsmlPropose);
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.name, "propose");
  const args = JSON.parse(calls[0]!.arguments);
  assert.equal(args.merchant_name, "Anthropic");
  assert.equal(args.recurrence, "recurring");
  assert.equal(args.amount, 20); // numeric coercion
  assert.deepEqual(args.evidence_refs, ["gmail-1a02a73212e8e7c3"]); // array coercion
});

test("parseChatPayload falls back to inline calls when tool_calls is empty", () => {
  const result = parseChatPayload({
    choices: [{ message: { content: DSML_CADENCE, tool_calls: [] } }],
    usage: { total_tokens: 42 },
  });
  assert.equal(result.toolCalls.length, 2);
  assert.equal(result.toolCalls[0]!.name, "compute_cadence");
  assert.equal(result.tokens, 42);
});

test("parseChatPayload prefers structured tool_calls over inline markup", () => {
  const result = parseChatPayload({
    choices: [
      {
        message: {
          content: DSML_CADENCE, // present but must be ignored
          tool_calls: [{ id: "call_1", type: "function", function: { name: "search_inbox", arguments: '{"query":"x"}' } }],
        },
      },
    ],
  });
  assert.equal(result.toolCalls.length, 1);
  assert.equal(result.toolCalls[0]!.name, "search_inbox");
});

test("no false positives on plain prose", () => {
  assert.deepEqual(parseInlineToolCalls("I will now propose the Anthropic subscription."), []);
});
