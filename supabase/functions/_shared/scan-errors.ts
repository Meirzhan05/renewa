// Map an internal/provider error string to a user-safe, categorized message. Raw provider text
// ("Insufficient Balance", "Bad Request", "Authentication Fails …") MUST NOT reach an end user, so
// anything unrecognized falls back to a generic message rather than passing through.

export type ScanErrorCategory =
  | "analysis-unavailable"
  | "inbox-authorization"
  | "worker-unavailable"
  | "generic";

const CATEGORY_PATTERNS: Array<[ScanErrorCategory, RegExp]> = [
  // LLM/analysis provider failures (billing, quota, key). Checked first — its "api key" beats the
  // inbox-auth patterns for an LLM auth error.
  ["analysis-unavailable", /insufficient\s+balance|insufficient\s+funds|current\s+quota|retry\s+budget|managed\s+page\s+analysis|incorrect\s+api\s+key|invalid\s+api\s+key|api\s+key/i],
  // Mailbox/OAuth access failures.
  ["inbox-authorization", /bad\s+request|reconnect|authorization\s+needs\s+attention|inbox\s+disconnected|invalid_grant|token/i],
  // Scan worker/runtime liveness.
  ["worker-unavailable", /scan\s+worker/i],
];

const MESSAGES: Record<ScanErrorCategory, string> = {
  "analysis-unavailable":
    "We couldn't finish scanning — our analysis service is temporarily unavailable. Please try again later.",
  "inbox-authorization":
    "We couldn't access your inbox. Please reconnect it and try again.",
  "worker-unavailable":
    "We couldn't finish scanning. Please try again shortly.",
  "generic":
    "We couldn't finish scanning. Please try again.",
};

export function categorizeScanError(internal: string | null | undefined): ScanErrorCategory {
  const text = internal ?? "";
  for (const [category, pattern] of CATEGORY_PATTERNS) {
    if (pattern.test(text)) return category;
  }
  return "generic";
}

/** A user-safe message for an internal scan error. Never returns the raw provider text. */
export function userFacingScanError(internal: string | null | undefined): string {
  return MESSAGES[categorizeScanError(internal)];
}
