import { projectRenewalDate } from "./email-discovery.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

Deno.test("projectRenewalDate advances one step per cycle", () => {
  assert(projectRenewalDate("weekly", "2026-08-01") === "2026-08-08", "weekly +7d");
  assert(projectRenewalDate("monthly", "2026-08-01") === "2026-09-01", "monthly +1m");
  assert(projectRenewalDate("quarterly", "2026-01-15") === "2026-04-15", "quarterly +3m");
  assert(projectRenewalDate("yearly", "2026-08-24") === "2027-08-24", "yearly +12m");
});

Deno.test("projectRenewalDate clamps to the shorter month", () => {
  // Jan 31 + 1 month has no Feb 31 → clamp to Feb 28 (2026 is not a leap year).
  assert(projectRenewalDate("monthly", "2026-01-31") === "2026-02-28", "month-end clamp");
});

Deno.test("projectRenewalDate rejects a non-ISO base date", () => {
  assert(projectRenewalDate("monthly", "not-a-date") === null, "invalid base → null");
  assert(projectRenewalDate("monthly", "2026-08-01T12:00:00Z") === null, "timestamp not accepted");
});
