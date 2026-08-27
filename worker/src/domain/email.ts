// Runtime-agnostic mail types and the deterministic keyword signals used as the
// classifier's graceful fallback. Ported from the Deno edge function's _shared/email-discovery.ts
// so the worker carries no Deno dependency. Pure — trivially unit-testable.

export type MailMetadata = {
  id: string;
  subject: string;
  sender: string;
  received_at: string;
  snippet: string;
};

export const billingEventTypes = [
  "created",
  "renewed",
  "price_changed",
  "canceled",
  "trial_started",
  "trial_ending",
] as const;
export type BillingEventType = (typeof billingEventTypes)[number];

export const billingCycles = ["weekly", "monthly", "quarterly", "yearly"] as const;
export type BillingCycle = (typeof billingCycles)[number];

export const subscriptionCategories = [
  "entertainment",
  "work",
  "cloud",
  "health",
  "learning",
  "other",
] as const;
export type SubscriptionCategory = (typeof subscriptionCategories)[number];

const strongBillingSignals = [
  "subscription",
  "renewal",
  "renews",
  "recurring",
  "membership",
  "trial ending",
  "price change",
  "price increase",
  "canceled",
  "cancelled",
  "abonnement",
  "renouvellement",
  "suscripción",
  "renovación",
  "подписк",
  "продлен",
  "жазылым",
];

const paymentSignals = [
  "receipt",
  "invoice",
  "payment",
  "charged",
  "billing",
  "order total",
  "facture",
  "reçu",
  "factura",
  "recibo",
  "оплата",
  "чек",
  "төлем",
];

const marketingSignals = [
  "sale",
  "offer",
  "newsletter",
  "save up to",
  "limited time",
  "unsubscribe",
  "promotion",
];

export function candidateSignalScore(message: MailMetadata): number {
  const subject = message.subject.toLowerCase();
  const sender = message.sender.toLowerCase();
  const snippet = message.snippet.toLowerCase();
  const combined = `${subject}\n${snippet}`;
  let score = 0;

  if (strongBillingSignals.some((signal) => combined.includes(signal))) score += 3;
  if (paymentSignals.some((signal) => combined.includes(signal))) score += 2;
  if (/\b(?:usd|eur|gbp|kzt|cad|aud|jpy)\b/i.test(combined)) score += 1;
  if (/[$€£₸¥]\s?\d|\d[.,]\d{2}\s?(?:usd|eur|gbp|kzt|cad|aud|jpy)/i.test(combined)) score += 1;
  if (/(billing|payments?|receipts?|invoices?|subscriptions?)[@.]/i.test(sender)) score += 1;
  if (marketingSignals.some((signal) => subject.includes(signal))) score -= 2;

  return score;
}

export function isLikelyBillingCandidate(message: MailMetadata): boolean {
  return candidateSignalScore(message) >= 2;
}

export function canonicalMerchantKey(value: string): string {
  const key = value
    .normalize("NFKD")
    .toLowerCase()
    .replace(/[^\p{Letter}\p{Number}]+/gu, "-")
    .replace(/(^-|-$)/g, "")
    .slice(0, 80);
  const asciiKey = key.replace(/[^a-z0-9-]/g, "").replace(/(^-|-$)/g, "");
  return asciiKey || "unknown-merchant";
}

/** The registrable-ish label from a sender address, e.g. "anthropic" from billing.anthropic.com. */
export function senderLabel(sender: string): string {
  const match = sender.match(/@([^>\s]+)/);
  if (match?.[1]) {
    const host = match[1].toLowerCase().split(".");
    return host.length >= 2 ? host[host.length - 2]! : host[0]!;
  }
  const name = sender.replace(/<[^>]*>/g, "").trim();
  return name || "unknown-merchant";
}

/** The full sender domain, e.g. "billing.anthropic.com". Empty string when unparseable. */
export function senderDomain(sender: string): string {
  const match = sender.match(/@([^>\s]+)/);
  return match?.[1] ? match[1].toLowerCase() : "";
}
