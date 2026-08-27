// Two-axis confidence-ladder routing. Given a VERIFIED, recurrence-reconciled assessment, route
// it on existence × confidence into one of two outcomes — present a candidate, or record a
// near-miss. Pure and deterministic; the human-confirmation gate lives downstream (a presented
// candidate still requires the user to confirm, and can be completed then). Node port of the Deno
// _shared/discovery-routing.ts.

import type { MerchantAssessment } from "./reasoner.ts";

export type RouteOutcome =
  | { kind: "present"; assessment: MerchantAssessment }
  | { kind: "near_miss"; reason: string; assessment: MerchantAssessment };

export type RoutingOptions = {
  minConfidence: number;
};

export const DEFAULT_ROUTING_OPTIONS: RoutingOptions = { minConfidence: 0.35 };

export function routeAssessment(
  assessment: MerchantAssessment,
  options: RoutingOptions = DEFAULT_ROUTING_OPTIONS,
): RouteOutcome {
  if (assessment.existence !== "high" || assessment.confidence < options.minConfidence) {
    return {
      kind: "near_miss",
      reason:
        assessment.abstain_reason ??
        (assessment.existence !== "high" ? "low_existence" : "low_confidence"),
      assessment,
    };
  }
  // A high-existence, confident merchant is surfaced even when a field (e.g. billing_cycle) is
  // still missing; the person fills the gap at the confirmation gate rather than in a separate ask.
  return { kind: "present", assessment };
}
