import { test } from "node:test";
import assert from "node:assert/strict";
import { isPermanentProviderError } from "../src/managed/provider-errors.ts";

test("billing/quota exhaustion is permanent", () => {
  assert.equal(isPermanentProviderError("Insufficient Balance"), true);
  assert.equal(isPermanentProviderError("402 insufficient_balance"), true);
  assert.equal(isPermanentProviderError("You exceeded your current quota, please check billing"), true);
  assert.equal(isPermanentProviderError("billing hard limit reached"), true);
});

test("authentication failures are permanent", () => {
  assert.equal(isPermanentProviderError("Authentication Fails, Your api key: ****0cde is invalid"), true);
  assert.equal(isPermanentProviderError("Invalid API key"), true);
  assert.equal(isPermanentProviderError("incorrect api key provided"), true);
  assert.equal(isPermanentProviderError("401 Unauthorized"), true);
});

test("transient errors are NOT permanent (keep retrying)", () => {
  assert.equal(isPermanentProviderError("LLM request timed out after 90000ms"), false);
  assert.equal(isPermanentProviderError("503 Service Unavailable"), false);
  assert.equal(isPermanentProviderError("429 Too Many Requests"), false);
  assert.equal(isPermanentProviderError("socket hang up"), false);
  assert.equal(isPermanentProviderError(""), false);
  assert.equal(isPermanentProviderError(null), false);
  assert.equal(isPermanentProviderError(undefined), false);
});
