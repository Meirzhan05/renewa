// Recall observability for the Tier-1 gate. A `skip` is a permanent drop, so triage recall is the
// ceiling on the whole system and is invisible by default — you cannot see what you dropped. This
// probe periodically routes a small random sample of SKIPPED mail through the same Tier-2 agent the
// look-set gets; anything the agent would have surfaced from that sample is a triage MISS, and the
// miss rate is the false-negative estimate. Measurement only — it never changes a scan's outcome.

import type { MailMetadata } from "../domain/email.ts";

export type SkipProbeOptions = {
  // Fraction of skipped mail to sample (e.g. 0.05). Applied per message.
  rate?: number;
  // Hard cap on the sample size, so the probe cost stays bounded regardless of skip volume.
  cap?: number;
  // Injectable RNG for deterministic tests; defaults to Math.random.
  rng?: () => number;
};

// Runs the same Tier-2 path over the sample and returns the merchant keys it would surface.
export type SkipProbeRunner = (messages: MailMetadata[]) => Promise<string[]>;

/** Draw a bounded random sample of skipped messages. Pure over its injected RNG. */
export function sampleSkips(skip: MailMetadata[], options: SkipProbeOptions = {}): MailMetadata[] {
  const rate = options.rate ?? 0.05;
  const cap = options.cap ?? 20;
  const rng = options.rng ?? Math.random;
  const sampled = skip.filter(() => rng() < rate);
  return sampled.slice(0, cap);
}

export type SkipProbeResult = {
  sampledCount: number;
  // Merchants the agent surfaced from mail Tier-1 had discarded → triage false negatives.
  missKeys: string[];
  // missKeys.length / sampledCount, or 0 when nothing was sampled.
  falseNegativeRate: number;
};

/**
 * Route a sample of skipped mail through the agent and record what it would have surfaced. The
 * result is a false-negative estimate for the Tier-1 gate; callers persist/expose it (task 7.2).
 */
export async function probeSkips(
  skip: MailMetadata[],
  runner: SkipProbeRunner,
  options: SkipProbeOptions = {},
): Promise<SkipProbeResult> {
  const sample = sampleSkips(skip, options);
  if (sample.length === 0) return { sampledCount: 0, missKeys: [], falseNegativeRate: 0 };
  const missKeys = await runner(sample);
  return {
    sampledCount: sample.length,
    missKeys,
    falseNegativeRate: missKeys.length / sample.length,
  };
}
