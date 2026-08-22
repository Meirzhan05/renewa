export type InsightSummarySource = "ai" | "deterministic";

export type InsightEvidenceSummary = {
  active_subscription_count: number;
  billing_event_count: number;
  monthly_snapshot_count: number;
};

export type StoredInsightProvenance = {
  source: InsightSummarySource;
  generated_at: string;
  evidence: InsightEvidenceSummary;
};

export type DeliveredInsightProvenance = StoredInsightProvenance & {
  is_cached: boolean;
};

type InsightPayloadLike = {
  generated_at: string;
  is_ai_generated: boolean;
  provenance?: Partial<StoredInsightProvenance>;
};

export function shouldUseCachedInsight(force: boolean, hasCachedReport: boolean): boolean {
  return !force && hasCachedReport;
}

export function shouldGenerateInsights(activeSubscriptionCount: number): boolean {
  return activeSubscriptionCount > 0;
}

export function insightEvidenceSummary(
  activeSubscriptionCount: number,
  billingEventCount: number,
  monthlySnapshotCount: number,
): InsightEvidenceSummary {
  return {
    active_subscription_count: Math.max(0, activeSubscriptionCount),
    billing_event_count: Math.max(0, billingEventCount),
    monthly_snapshot_count: Math.max(0, monthlySnapshotCount),
  };
}

export function attachInsightProvenance<T extends InsightPayloadLike>(
  payload: T,
  source: InsightSummarySource,
  evidence: InsightEvidenceSummary,
): T & { provenance: StoredInsightProvenance } {
  return {
    ...payload,
    provenance: {
      source,
      generated_at: payload.generated_at,
      evidence,
    },
  };
}

export function deliverInsightReport<T extends InsightPayloadLike>(
  payload: T,
  evidence: InsightEvidenceSummary,
  isCached: boolean,
): T & { provenance: DeliveredInsightProvenance } {
  const source: InsightSummarySource = payload.provenance?.source === "ai" || payload.is_ai_generated
    ? "ai"
    : "deterministic";
  const generatedAt = typeof payload.provenance?.generated_at === "string"
    ? payload.provenance.generated_at
    : payload.generated_at;
  const storedEvidence = isEvidenceSummary(payload.provenance?.evidence)
    ? payload.provenance.evidence
    : evidence;

  return {
    ...payload,
    provenance: {
      source,
      generated_at: generatedAt,
      evidence: storedEvidence,
      is_cached: isCached,
    },
  };
}

export function insightOutcomeLog(
  outcome: "cache_hit" | "ai_generated" | "ai_fallback" | "validation_failed" | "request_failed",
  evidence: InsightEvidenceSummary,
): string {
  return JSON.stringify({ event: "insights_refresh", outcome, evidence });
}

function isEvidenceSummary(value: unknown): value is InsightEvidenceSummary {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Record<string, unknown>;
  return [
    candidate.active_subscription_count,
    candidate.billing_event_count,
    candidate.monthly_snapshot_count,
  ].every((count) => typeof count === "number" && Number.isFinite(count) && count >= 0);
}
