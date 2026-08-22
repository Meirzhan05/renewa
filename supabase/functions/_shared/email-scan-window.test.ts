import {
  cursorRecoveryLookbackDays,
  gmailHistoricalQuery,
  initialMailboxLookbackDays,
  microsoftHistoricalFilter,
} from "./email-scan-window.ts";

function assertEquals<T>(actual: T, expected: T, message?: string): void {
  if (actual !== expected) {
    throw new Error(message ?? `Expected ${expected}, received ${actual}`);
  }
}

Deno.test("first discovery has a six-month lookback", () => {
  assertEquals(initialMailboxLookbackDays, 180);
  assertEquals(
    gmailHistoricalQuery(initialMailboxLookbackDays),
    "newer_than:180d",
  );
});

Deno.test("cursor recovery uses a shorter ninety-day lookback", () => {
  const now = Date.UTC(2026, 7, 21, 0, 0, 0);
  assertEquals(cursorRecoveryLookbackDays, 90);
  assertEquals(
    microsoftHistoricalFilter(cursorRecoveryLookbackDays, now),
    "receivedDateTime ge 2026-05-23T00:00:00.000Z",
  );
});
