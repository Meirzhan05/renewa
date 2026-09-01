// Classify an LLM/analysis provider error as permanent (will not recover on retry) vs transient.
//
// A permanent error is one where retrying only wastes the budget (and real money/latency) and, worse,
// loops forever under the durable dispatcher: billing/quota exhaustion and authentication failures.
// Observed in production: DeepSeek "Insufficient Balance" and "Authentication Fails, Your api key … is
// invalid" retried every minute for 13+ hours. Everything else (timeouts, 5xx, rate limits) stays
// transient so a genuine blip still gets the normal retry budget.

const PERMANENT_PATTERNS: RegExp[] = [
  /insufficient\s+balance/i,
  /insufficient\s+funds/i,
  /exceeded\s+your\s+current\s+quota/i,
  /billing\s+(?:hard\s+)?limit/i,
  /invalid[\s_-]*api[\s_-]*key/i,
  /incorrect\s+api\s+key/i,
  /authentication\s+fail/i,
  /invalid\s+authentication/i,
  /\bunauthorized\b/i,
  // HTTP status codes for auth/payment, as they commonly appear in provider error strings.
  /\b401\b/,
  /\b402\b/,
];

/** True when the provider error will not recover on retry (billing/quota/auth). */
export function isPermanentProviderError(message: string | null | undefined): boolean {
  if (!message) return false;
  return PERMANENT_PATTERNS.some((pattern) => pattern.test(message));
}
