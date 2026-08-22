import { assertEquals } from "jsr:@std/assert";
import {
  gmailWatchRequest,
  microsoftSubscriptionRequest,
  monitoringHealthForError,
  monitoringRenewalDue,
} from "./inbox-monitoring-policy.ts";

Deno.test("Gmail monitoring is limited to the inbox label", () => {
  assertEquals(gmailWatchRequest("projects/renewa/topics/inbox"), {
    topicName: "projects/renewa/topics/inbox",
    labelIds: ["INBOX"],
  });
});

Deno.test("Microsoft monitoring request uses a private client state and inbox resource", () => {
  const request = microsoftSubscriptionRequest(
    "https://example.com/monitor",
    "private-state",
    0,
  );
  assertEquals(request.resource, "me/mailFolders('inbox')/messages");
  assertEquals(request.clientState, "private-state");
  assertEquals(request.expirationDateTime, "1970-01-03T00:00:00.000Z");
});

Deno.test("monitoring renews before expiry and classifies authorization failures", () => {
  const now = Date.parse("2026-08-22T00:00:00.000Z");
  assertEquals(monitoringRenewalDue("2026-08-22T12:00:00.000Z", now), true);
  assertEquals(monitoringRenewalDue("2026-08-24T00:00:00.000Z", now), false);
  assertEquals(
    monitoringHealthForError("Mail access expired. Reconnect your inbox."),
    "reconnect_required",
  );
  assertEquals(monitoringHealthForError("Microsoft returned 503"), "degraded");
});
