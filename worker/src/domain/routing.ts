// Two-axis confidence-ladder routing. Given a VERIFIED, recurrence-reconciled assessment, route
// it on existence × completeness into one of three outcomes — present a candidate, ask a single
// clarification, or record a near-miss. Pure and deterministic; the human-confirmation gate lives
// downstream (present and clarify both still require the user to confirm). Node port of the Deno
// _shared/discovery-routing.ts.

import type { MerchantAssessment } from "./reasoner.ts";

export type RouteOutcome =
  | { kind: "present"; assessment: MerchantAssessment }
  | { kind: "clarify"; field: string; assessment: MerchantAssessment }
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
  if (assessment.completeness === "complete") {
    return { kind: "present", assessment };
  }
  return {
    kind: "clarify",
    field: firstMissingField(assessment),
    assessment,
  };
}

/** Choose which missing field to ask about. Prefer billing_cycle — the common receipt gap. */
export function firstMissingField(assessment: MerchantAssessment): string {
  if (assessment.missing_fields.includes("billing_cycle")) return "billing_cycle";
  return assessment.missing_fields[0] ?? "billing_cycle";
}
