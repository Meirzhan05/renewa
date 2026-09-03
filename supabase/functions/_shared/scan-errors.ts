// Map an internal/provider error string to a user-safe, categorized message. Raw provider text
// ("Insufficient Balance", "Bad Request", "Authentication Fails …") MUST NOT reach an end user, so
// anything unrecognized falls back to a generic message rather than passing through.

export type ScanErrorCategory =
  | "analysis-unavailable"
  | "inbox-authorization"
  | "provider-rate-limited"
  | "provider-unavailable"
  | "worker-unavailable"
  | "generic";

/**
 * What a mail provider actually said when a request failed, decided from the HTTP status at the
 * point of failure.
 *
 * This exists because the status used to be thrown away: every failed Gmail request raised the same
 * "Reconnect your inbox" text, so a 429 and a revoked token were indistinguishable. Worse, that text
 * was then pattern-matched by `categorizeScanError` — whose `inbox-authorization` regex matches the
 * word "reconnect" that our own code had just written. The system diagnosed a failure from its own
 * guess about the failure, and users were sent to re-authorize healthy inboxes.
 */
export type ProviderFailureClass =
  | "authorization"
  | "rate-limited"
  | "provider-unavailable"
  | "provider-failure";

const CATEGORY_BY_CLASS: Record<ProviderFailureClass, ScanErrorCategory> = {
  "authorization": "inbox-authorization",
  "rate-limited": "provider-rate-limited",
  "provider-unavailable": "provider-unavailable",
  "provider-failure": "generic",
};

/** Coarse on purpose: the goal is to stop conflating "your credentials are gone" with "try again". */
export function classifyProviderStatus(status: number): ProviderFailureClass {
  if (status === 401 || status === 403) return "authorization";
  if (status === 429) return "rate-limited";
  if (status >= 500) return "provider-unavailable";
  return "provider-failure";
}

/** Retrying a revoked token only delays the one message that would help, so it is not retryable. */
export function isRetryableProviderFailure(value: ProviderFailureClass): boolean {
  return value === "rate-limited" || value === "provider-unavailable";
}

// The class travels as a leading tag so it survives being written to `email_scan_jobs.error_message`
// and read back later. A stored failure can then be diagnosed without re-running the scan, and
// nothing downstream has to re-derive the class from prose.
const CLASS_TAG = /^\[(authorization|rate-limited|provider-unavailable|provider-failure)\]\s*/;

export function taggedProviderFailure(
  value: ProviderFailureClass,
  detail: string,
): string {
  return `[${value}] ${detail}`;
}

/** The class carried by an internal error string, or null when it carries none. */
export function providerFailureClassOf(
  internal: string | null | undefined,
): ProviderFailureClass | null {
  const match = CLASS_TAG.exec(internal ?? "");
  return match ? match[1] as ProviderFailureClass : null;
}

const CATEGORY_PATTERNS: Array<[ScanErrorCategory, RegExp]> = [
  // LLM/analysis provider failures (billing, quota, key). Checked first — its "api key" beats the
  // inbox-auth patterns for an LLM auth error.
  ["analysis-unavailable", /insufficient\s+balance|insufficient\s+funds|current\s+quota|retry\s+budget|managed\s+page\s+analysis|incorrect\s+api\s+key|invalid\s+api\s+key|api\s+key/i],
  // Mailbox/OAuth access failures. "reconnect" is deliberately NOT matched here any more: it is a
  // word this codebase writes, not one a provider says, and matching it is what let a rate limit be
  // reported as a disconnected inbox. Anything with a real status behind it arrives tagged instead.
  ["inbox-authorization", /bad\s+request|authorization\s+needs\s+attention|inbox\s+disconnected|invalid_grant|token/i],
  // Scan worker/runtime liveness.
  ["worker-unavailable", /scan\s+worker/i],
];

const MESSAGES: Record<ScanErrorCategory, string> = {
  "analysis-unavailable":
    "We couldn't finish scanning — our analysis service is temporarily unavailable. Please try again later.",
  "inbox-authorization":
    "We couldn't access your inbox. Please reconnect it and try again.",
  "provider-rate-limited":
    "Your mail provider is limiting how fast we can read your inbox. We'll pick up where we left off — try again in a few minutes.",
  "provider-unavailable":
    "Your mail provider is temporarily unavailable. Nothing is wrong with your connection — please try again shortly.",
  "worker-unavailable":
    "We couldn't finish scanning. Please try again shortly.",
  "generic":
    "We couldn't finish scanning. Please try again.",
};

export function categorizeScanError(internal: string | null | undefined): ScanErrorCategory {
  const text = internal ?? "";
  // An explicit class always wins. Pattern matching is the fallback for errors raised somewhere that
  // never had a status to classify — never a way to second-guess one that did.
  const tagged = providerFailureClassOf(text);
  if (tagged) return CATEGORY_BY_CLASS[tagged];
  for (const [category, pattern] of CATEGORY_PATTERNS) {
    if (pattern.test(text)) return category;
  }
  return "generic";
}

/** A user-safe message for an internal scan error. Never returns the raw provider text. */
export function userFacingScanError(internal: string | null | undefined): string {
  return MESSAGES[categorizeScanError(internal)];
}
