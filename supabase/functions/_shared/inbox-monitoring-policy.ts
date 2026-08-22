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
  return /reconnect|access expired|invalid.*token|unauthori[sz]ed/i.test(
      message,
    )
    ? "reconnect_required"
    : "degraded";
}
