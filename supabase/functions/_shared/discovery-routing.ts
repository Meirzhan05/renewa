// Two-axis confidence-ladder routing. Given a VERIFIED merchant assessment, route it on
// existence × confidence into one of two outcomes — present a candidate, or record a near-miss.
// Pure and deterministic; the human-confirmation gate lives downstream (a presented candidate
// still requires the user to confirm, and can be completed then).

import type { MerchantAssessment } from "./agentic-reasoner.ts";

export type RouteOutcome =
  | { kind: "present"; assessment: MerchantAssessment }
  | { kind: "near_miss"; reason: string; assessment: MerchantAssessment };

export type RoutingOptions = {
  // Below this confidence, even a "high existence" assessment is treated as a near-miss so a
  // rushed/under-evidenced loop never surfaces a nag. Present sits above it.
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
      reason: assessment.abstain_reason ??
        (assessment.existence !== "high" ? "low_existence" : "low_confidence"),
      assessment,
    };
  }
  // A high-existence, confident merchant is surfaced even when a field (e.g. billing_cycle) is
  // still missing; the person fills the gap at the confirmation gate rather than in a separate ask.
  return { kind: "present", assessment };
}
