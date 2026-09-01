import { categorizeScanError, userFacingScanError } from "./scan-errors.ts";

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
