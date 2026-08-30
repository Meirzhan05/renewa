import { managedRunConcurrencyKey } from "./managed-inbox-runtime.ts";

function assertEquals<T>(actual: T, expected: T): void {
  if (actual !== expected) throw new Error(`expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

Deno.test("connections owned by one user share a managed scan concurrency key", () => {
  assertEquals(managedRunConcurrencyKey("user-a"), managedRunConcurrencyKey("user-a"));
  assertEquals(managedRunConcurrencyKey("user-a") === managedRunConcurrencyKey("user-b"), false);
});
