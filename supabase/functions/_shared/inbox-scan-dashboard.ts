export type DashboardEvidenceBundle = {
  canonical_merchant_key: string;
  lifecycle_state: "current" | "ended" | "uncertain";
  resolution_reason: string;
};

export type DashboardEvidenceEvent = {
  canonical_merchant_key: string | null;
  merchant_name: string;
  event_type: string;
  source_received_at: string;
};

export function buildLearningSummary(
  bundles: DashboardEvidenceBundle[],
  events: DashboardEvidenceEvent[],
) {
  const eventByMerchant = new Map<string, DashboardEvidenceEvent>();
  for (const event of events) {
    if (event.canonical_merchant_key && !eventByMerchant.has(event.canonical_merchant_key)) {
      eventByMerchant.set(event.canonical_merchant_key, event);
    }
  }

  return {
    ended_count: bundles.filter((bundle) => bundle.lifecycle_state === "ended").length,
    uncertain_count: bundles.filter((bundle) => bundle.lifecycle_state === "uncertain").length,
    items: bundles
      .filter((bundle) => bundle.lifecycle_state !== "current")
      .slice(0, 6)
      .flatMap((bundle) => {
        const event = eventByMerchant.get(bundle.canonical_merchant_key);
        if (!event) return [];
        return [{
          merchant_name: event.merchant_name,
          outcome: bundle.lifecycle_state,
          event_type: event.event_type,
          received_at: event.source_received_at,
          explanation: learningExplanation(bundle.lifecycle_state, bundle.resolution_reason),
        }];
      }),
  };
}

function learningExplanation(
  state: DashboardEvidenceBundle["lifecycle_state"],
  reason: string,
): string {
  if (state === "ended") return "Later ending evidence was found, so no action is needed.";
  if (state === "uncertain") return "There is not enough current renewal evidence to request a change.";
  return reason.slice(0, 180);
}
