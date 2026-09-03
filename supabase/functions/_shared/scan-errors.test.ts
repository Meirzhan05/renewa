import {
  categorizeScanError,
  classifyProviderStatus,
  isRetryableProviderFailure,
  providerFailureClassOf,
  taggedProviderFailure,
  userFacingScanError,
} from "./scan-errors.ts";

function assertEquals<T>(actual: T, expected: T, msg?: string): void {
  if (actual !== expected) throw new Error(msg ?? `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

Deno.test("raw LLM billing/auth errors map to analysis-unavailable", () => {
  assertEquals(categorizeScanError("Insufficient Balance"), "analysis-unavailable");
  assertEquals(categorizeScanError("Managed page analysis exhausted its retry budget."), "analysis-unavailable");
  assertEquals(categorizeScanError("Authentication Fails, Your api key: ****0cde is invalid"), "analysis-unavailable");
});

Deno.test("mailbox/OAuth errors map to inbox-authorization", () => {
  assertEquals(categorizeScanError("Bad Request"), "inbox-authorization");
  assertEquals(categorizeScanError("Inbox authorization needs attention."), "inbox-authorization");
  assertEquals(categorizeScanError("Inbox disconnected."), "inbox-authorization");
});

Deno.test("worker liveness errors map to worker-unavailable", () => {
  assertEquals(categorizeScanError("Scan worker is unavailable — please try again shortly."), "worker-unavailable");
  assertEquals(categorizeScanError("Scan worker did not complete the job in time."), "worker-unavailable");
});

Deno.test("unknown/empty falls back to generic", () => {
  assertEquals(categorizeScanError("One or more scan pages could not finish."), "generic");
  assertEquals(categorizeScanError(""), "generic");
  assertEquals(categorizeScanError(null), "generic");
});

Deno.test("user-facing message never contains raw provider text", () => {
  for (const raw of ["Insufficient Balance", "Bad Request", "Authentication Fails, api key invalid", "502 Bad Gateway"]) {
    const msg = userFacingScanError(raw);
    assertEquals(/insufficient balance|bad request|api key|502/i.test(msg), false, `leaked raw text for "${raw}": ${msg}`);
  }
});

// The bug these lock: every failed Gmail request threw the same "Reconnect your inbox" text, and
// `categorizeScanError` then matched the word "reconnect" that our own code had just written. A 429
// during a long scan was reported as a disconnected inbox, and a user was sent to re-authorize a
// connection created sixty seconds earlier.

Deno.test("provider status maps to the failure that actually happened", () => {
  assertEquals(classifyProviderStatus(401), "authorization");
  assertEquals(classifyProviderStatus(403), "authorization");
  assertEquals(classifyProviderStatus(429), "rate-limited");
  assertEquals(classifyProviderStatus(500), "provider-unavailable");
  assertEquals(classifyProviderStatus(503), "provider-unavailable");
  // Deliberately not special-cased: a 404 is not the failure this exists to fix.
  assertEquals(classifyProviderStatus(404), "provider-failure");
  assertEquals(classifyProviderStatus(418), "provider-failure");
});

Deno.test("a classified failure reaches the user as itself, not as an auth problem", () => {
  const throttled = taggedProviderFailure("rate-limited", "Gmail could not be read.");
  assertEquals(categorizeScanError(throttled), "provider-rate-limited");
  const down = taggedProviderFailure("provider-unavailable", "Gmail could not be read.");
  assertEquals(categorizeScanError(down), "provider-unavailable");
  const denied = taggedProviderFailure("authorization", "Gmail could not be read.");
  assertEquals(categorizeScanError(denied), "inbox-authorization");
  const other = taggedProviderFailure("provider-failure", "Gmail could not be read.");
  assertEquals(categorizeScanError(other), "generic");
});

Deno.test("only an authorization failure tells the user to reconnect", () => {
  const reconnect = userFacingScanError(taggedProviderFailure("authorization", "Gmail could not be read."));
  if (!reconnect.includes("reconnect")) {
    throw new Error("a genuine authorization failure must still ask the user to reconnect");
  }
  for (const cls of ["rate-limited", "provider-unavailable", "provider-failure"] as const) {
    const message = userFacingScanError(taggedProviderFailure(cls, "Gmail could not be read."));
    if (/reconnect/i.test(message)) {
      throw new Error(`${cls} must not tell the user to reconnect: ${message}`);
    }
  }
});

Deno.test("an untagged error still falls back to pattern matching", () => {
  assertEquals(categorizeScanError("Inbox authorization needs attention."), "inbox-authorization");
  assertEquals(categorizeScanError("Insufficient Balance"), "analysis-unavailable");
  assertEquals(categorizeScanError("Scan worker is unavailable."), "worker-unavailable");
});

Deno.test("no provider response body can reach a user-facing message", () => {
  const leaky = taggedProviderFailure(
    "rate-limited",
    "Quota exceeded for quota metric 'Queries' of service 'gmail.googleapis.com' for user 12345",
  );
  const shown = userFacingScanError(leaky);
  for (const secret of ["gmail.googleapis.com", "12345", "Queries"]) {
    if (shown.includes(secret)) throw new Error(`provider text leaked: ${shown}`);
  }
});

Deno.test("the class survives a round trip through storage", () => {
  const stored = taggedProviderFailure("rate-limited", "Gmail could not be read.");
  assertEquals(providerFailureClassOf(stored), "rate-limited");
  assertEquals(providerFailureClassOf("Gmail could not be read."), null);
  assertEquals(providerFailureClassOf(null), null);
});

Deno.test("retry only what retrying can fix", () => {
  assertEquals(isRetryableProviderFailure("rate-limited"), true);
  assertEquals(isRetryableProviderFailure("provider-unavailable"), true);
  // Retrying a revoked token just delays the one message that would help.
  assertEquals(isRetryableProviderFailure("authorization"), false);
  assertEquals(isRetryableProviderFailure("provider-failure"), false);
});

// A genuine authorization failure raised WITHOUT an HTTP status (a missing refresh token) must still
// reach the user as "reconnect". Narrowing the auth pattern orphaned this case until it was tagged.
Deno.test("an auth failure with no status still asks the user to reconnect", () => {
  const expired = taggedProviderFailure("authorization", "Mail access expired.");
  assertEquals(categorizeScanError(expired), "inbox-authorization");
  if (!userFacingScanError(expired).includes("reconnect")) {
    throw new Error("an expired credential must still ask the user to reconnect");
  }
});
