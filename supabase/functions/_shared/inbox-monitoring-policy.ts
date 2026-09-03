import { providerFailureClassOf } from "./scan-errors.ts";

export const monitoringRenewalLeadMilliseconds = 24 * 60 * 60 * 1000;
export const microsoftSubscriptionLifetimeMilliseconds = 2 * 24 * 60 * 60 *
  1000;

export function gmailWatchRequest(topicName: string): Record<string, unknown> {
  return { topicName, labelIds: ["INBOX"] };
}

export function microsoftSubscriptionRequest(
  notificationURL: string,
  clientState: string,
  now = Date.now(),
): Record<string, unknown> {
  return {
    changeType: "created,updated",
    notificationUrl: notificationURL,
    resource: "me/mailFolders('inbox')/messages",
    expirationDateTime: new Date(
      now + microsoftSubscriptionLifetimeMilliseconds,
    ).toISOString(),
    clientState,
  };
}

export function monitoringRenewalDue(
  expiresAt: string | null,
  now = Date.now(),
): boolean {
  if (!expiresAt) return true;
  const expiry = new Date(expiresAt).getTime();
  return !Number.isFinite(expiry) ||
    expiry <= now + monitoringRenewalLeadMilliseconds;
}

export function monitoringHealthForError(
  message: string,
): "degraded" | "reconnect_required" {
  // A classified failure decides this outright. Only an authorization failure means the credentials
  // are the problem — a rate limit or a provider outage leaves a perfectly good connection, and
  // marking it `reconnect_required` would push the user to re-authorize for nothing. The text
  // patterns remain for errors raised somewhere that had no status to classify.
  const failureClass = providerFailureClassOf(message);
  if (failureClass) {
    return failureClass === "authorization" ? "reconnect_required" : "degraded";
  }
  return /reconnect|access expired|invalid.*token|unauthori[sz]ed/i.test(
      message,
    )
    ? "reconnect_required"
    : "degraded";
}
