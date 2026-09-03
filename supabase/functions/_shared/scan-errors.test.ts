import {
  categorizeScanError,
  classifyProviderFailure,
  classifyProviderStatus,
  providerFailureReason,
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

// The failure this was shipped wrong for: Gmail returns 403 for per-user quota, not 429. Three pages
// succeeded on a token minted six seconds earlier, page four came back 403, and the scan told the
// user to reconnect a healthy inbox — and, because authorization is not retryable, never retried the
// one failure the retry existed for.
Deno.test("Gmail quota exhaustion is rate limiting, not a revoked credential", () => {
  for (const reason of ["userRateLimitExceeded", "rateLimitExceeded", "dailyLimitExceeded"]) {
    assertEquals(classifyProviderFailure(403, reason), "rate-limited");
    assertEquals(isRetryableProviderFailure(classifyProviderFailure(403, reason)), true);
  }
});

Deno.test("a genuinely revoked credential is still authorization", () => {
  assertEquals(classifyProviderFailure(401, null), "authorization");
  assertEquals(classifyProviderFailure(403, "authError"), "authorization");
  assertEquals(classifyProviderFailure(401, "InvalidAuthenticationToken"), "authorization");
  assertEquals(classifyProviderFailure(403, "insufficientPermissions"), "authorization");
  // Without a reason, a bare 403 keeps the conservative reading.
  assertEquals(classifyProviderFailure(403, null), "authorization");
});

Deno.test("a reason overrides the status in both directions", () => {
  // Graph throttling arrives as 429 already, but the reason must not fight the status.
  assertEquals(classifyProviderFailure(429, "TooManyRequests"), "rate-limited");
  // An unrecognized reason falls back to the status rather than guessing.
  assertEquals(classifyProviderFailure(500, "somethingNovel"), "provider-unavailable");
  assertEquals(classifyProviderFailure(418, "somethingNovel"), "provider-failure");
});

Deno.test("the reason is extracted from real provider error shapes", () => {
  // Google
  assertEquals(
    providerFailureReason({
      error: {
        code: 403,
        message: "User-rate limit exceeded.",
        errors: [{ domain: "usageLimits", reason: "userRateLimitExceeded", message: "…" }],
        status: "PERMISSION_DENIED",
      },
    }),
    "userRateLimitExceeded",
  );
  // Microsoft Graph
  assertEquals(
    providerFailureReason({ error: { code: "TooManyRequests", message: "…" } }),
    "TooManyRequests",
  );
  assertEquals(providerFailureReason({ error: { message: "no machine reason here" } }), null);
  assertEquals(providerFailureReason(null), null);
  assertEquals(providerFailureReason("not json"), null);
});

Deno.test("only identifier-shaped reasons are carried, never provider prose", () => {
  // Free text must not ride along under the guise of a reason.
  assertEquals(
    providerFailureReason({ error: { errors: [{ reason: "Quota exceeded for user 12345" }] } }),
    null,
  );
  assertEquals(
    providerFailureReason({ error: { code: "a".repeat(80) } }),
    null,
  );
});
