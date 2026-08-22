import { assertEquals, assertNotEquals } from "jsr:@std/assert";
import { buildLearningSummary } from "./inbox-scan-dashboard.ts";

Deno.test("dashboard learning summary excludes raw email evidence and current subscriptions", () => {
  const summary = buildLearningSummary(
    [
      { canonical_merchant_key: "openai", lifecycle_state: "ended", resolution_reason: "explicit_cancellation" },
      { canonical_merchant_key: "grammarly", lifecycle_state: "uncertain", resolution_reason: "no_current_renewal" },
      { canonical_merchant_key: "netflix", lifecycle_state: "current", resolution_reason: "recent_renewal" },
    ],
    [
      { canonical_merchant_key: "openai", merchant_name: "OpenAI", event_type: "canceled", source_received_at: "2026-08-10T12:00:00.000Z" },
      { canonical_merchant_key: "grammarly", merchant_name: "Grammarly", event_type: "created", source_received_at: "2026-08-09T12:00:00.000Z" },
      { canonical_merchant_key: "netflix", merchant_name: "Netflix", event_type: "renewed", source_received_at: "2026-08-08T12:00:00.000Z" },
      { canonical_merchant_key: "other-user-only", merchant_name: "Private Merchant", event_type: "created", source_received_at: "2026-08-07T12:00:00.000Z" },
    ],
  );

  assertEquals(summary.ended_count, 1);
  assertEquals(summary.uncertain_count, 1);
  assertEquals(summary.items.map((item) => item.merchant_name), ["OpenAI", "Grammarly"]);
  assertEquals(summary.items.some((item) => item.merchant_name == "Private Merchant"), false);
  assertEquals(Object.keys(summary.items[0]).sort(), ["event_type", "explanation", "merchant_name", "outcome", "received_at"]);
  assertNotEquals(JSON.stringify(summary), "raw email body");
});
