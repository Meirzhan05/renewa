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

/**
 * Domains that front MANY merchants: payment processors and app stores. The sender identifies the
 * processor, not the merchant, so these must NEVER become a merchant identity — keying on them would
 * fuse every App Store subscription into a single card, silently hiding subscriptions from the user.
 *
 * Matched on the registrable label (not the full domain) so country variants are covered too.
 *
 * An aggregator missing from this list degrades to name-derived identity's old behaviour (duplicate
 * cards, which a human can resolve) and never to over-merging (a hidden subscription, which they
 * cannot see to resolve). That asymmetry is why this is a conservative allow-duplicates list.
 */
const AGGREGATOR_LABELS = new Set([
  "apple",
  "google",
  "paypal",
  "stripe",
  "paddle",
  "chargebee",
  "fastspring",
  "recurly",
  "braintreepayments",
  "microsoft",
  "shopify",
  "gumroad",
  "patreon",
  "lemonsqueezy",
]);

/**
 * Two-part public suffixes. Without these, the registrable label of "vendor.co.uk" would come out as
 * "co" and every UK vendor would collapse into one identity — the over-merge this design forbids.
 */
const MULTI_PART_SUFFIXES = new Set([
  "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk",
  "com.au", "net.au", "org.au", "co.nz", "co.za",
  "co.jp", "or.jp", "co.kr", "com.cn", "com.hk", "com.tw", "com.sg",
  "com.br", "com.mx", "com.ar", "co.in", "com.tr",
]);

/**
 * The registrable label of a sender domain — "anthropic" from "no-reply@mail.anthropic.com", and
 * "vendor" from "billing@vendor.co.uk". Empty string when the sender has no parseable domain.
 *
 * Unlike `senderLabel`, this is public-suffix aware and is safe to use as an identity.
 */
export function registrableLabel(sender: string): string {
  const domain = senderDomain(sender);
  if (!domain) return "";
  const parts = domain.split(".").filter(Boolean);
  if (parts.length < 2) return parts[0] ?? "";
  const lastTwo = `${parts[parts.length - 2]}.${parts[parts.length - 1]}`;
  const suffixLength = MULTI_PART_SUFFIXES.has(lastTwo) ? 2 : 1;
  return parts[parts.length - 1 - suffixLength] ?? "";
}

/**
 * The canonical merchant identity for a proposal.
 *
 * Identity comes from WHO BILLED (the evidence sender's registrable domain), not from what the model
 * decided to call it. The model names one vendor inconsistently across emails ("Anthropic" on one,
 * "Anthropic (Claude Pro)" on the next); slugging that name made those two identities, which defeated
 * every dedup layer at once. The sender is declared by the vendor and stable across their mail.
 *
 * Falls back to the display name when the sender is unparseable or is a shared billing processor
 * (see `AGGREGATOR_LABELS`). Always yields a key — `canonicalMerchantKey` returns the
 * "unknown-merchant" sentinel rather than failing, so a proposal is never dropped for lack of identity.
 *
 * Deliberately returns the bare label ("anthropic") rather than the full domain ("anthropic-com") so
 * it stays continuous with the name-derived keys already stored in `subscriptions` and
 * `merchant_discovery_suppressions` — for the common case where brand, name, and domain agree, the
 * key is unchanged and existing suppressions keep matching.
 *
 * Pure.
 */
export function resolveMerchantIdentity(sender: string, displayName: string): string {
  const label = registrableLabel(sender);
  if (label && !AGGREGATOR_LABELS.has(label)) {
    const key = canonicalMerchantKey(label);
    if (key !== "unknown-merchant") return key;
  }
  return canonicalMerchantKey(displayName);
}
