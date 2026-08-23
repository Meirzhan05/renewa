import {
  attachInsightProvenance,
  deliverInsightReport,
  insightEvidenceSummary,
  shouldGenerateInsights,
  shouldUseCachedInsight,
} from "./insights-provenance.ts";

function assertEquals<T>(actual: T, expected: T, message?: string): void {
  if (actual !== expected) {
    throw new Error(message ?? `Expected ${expected}, received ${actual}`);
  }
}

const evidence = insightEvidenceSummary(4, 7, 2);
const generatedAt = "2026-08-22T04:00:00.000Z";

Deno.test("fresh AI output carries uncached AI provenance", () => {
  const stored = attachInsightProvenance({
    summary: "Your commitments are stable.",
    cards: [],
    generated_at: generatedAt,
    is_ai_generated: true,
  }, "ai", evidence);
  const delivered = deliverInsightReport(stored, evidence, false);

  assertEquals(delivered.provenance.source, "ai");
  assertEquals(delivered.provenance.is_cached, false);
  assertEquals(delivered.provenance.evidence.billing_event_count, 7);
});

Deno.test("cached report preserves generation source and marks this delivery cached", () => {
  const stored = attachInsightProvenance({
    summary: "Your commitments are stable.",
    cards: [],
    generated_at: generatedAt,
    is_ai_generated: true,
  }, "ai", evidence);
  const delivered = deliverInsightReport(stored, insightEvidenceSummary(99, 99, 99), true);

  assertEquals(delivered.provenance.source, "ai");
  assertEquals(delivered.provenance.is_cached, true);
  assertEquals(delivered.provenance.evidence.active_subscription_count, 4);
});

Deno.test("generation or validation fallback remains explicitly deterministic", () => {
  const fallback = attachInsightProvenance({
    summary: "Your next renewal is Example on 2026-09-01.",
    cards: [],
    generated_at: generatedAt,
    is_ai_generated: false,
  }, "deterministic", evidence);
  const delivered = deliverInsightReport(fallback, evidence, false);

  assertEquals(delivered.provenance.source, "deterministic");
  assertEquals(delivered.provenance.is_cached, false);
});

Deno.test("forced refresh bypasses a matching cache entry", () => {
  assertEquals(shouldUseCachedInsight(false, true), true);
  assertEquals(shouldUseCachedInsight(true, true), false);
});

Deno.test("accounts without active subscriptions do not invoke insight generation", () => {
  assertEquals(shouldGenerateInsights(0), false);
  assertEquals(shouldGenerateInsights(1), true);
});
