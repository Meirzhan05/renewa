import type { BillingCycle, BillingEvent, MerchantLifecycleState } from "./email-discovery.ts";

export type InboxClarificationKind =
  | "lifecycle_check"
  | "identity_check"
  | "billing_cycle_check";

export type InboxClarificationChoice = {
  value: string;
  title: string;
};

export type InboxClarificationDraft = {
  kind: InboxClarificationKind;
  question: string;
  explanation: string;
  choices: InboxClarificationChoice[];
  priority: number;
};

const RECENT_EVIDENCE_WINDOW_MS = 90 * 24 * 60 * 60 * 1_000;
const minimumConfidence = 0.82;

function recentPaidEvidence(event: BillingEvent, receivedAt: string, now = Date.now()): boolean {
  const received = Date.parse(receivedAt);
  return Number.isFinite(received) && now - received >= 0 && now - received <= RECENT_EVIDENCE_WINDOW_MS &&
    event.confidence >= minimumConfidence && typeof event.amount === "number" && event.amount > 0 && Boolean(event.currency) &&
    !["trial_started", "marketing"].includes(event.event_type);
}

export function lifecycleClarificationDraft(input: {
  event: BillingEvent;
  receivedAt: string;
  lifecycleState: MerchantLifecycleState;
  now?: number;
}): InboxClarificationDraft | null {
  if (input.lifecycleState !== "uncertain" || !recentPaidEvidence(input.event, input.receivedAt, input.now)) return null;
  return {
    kind: "lifecycle_check",
    question: `Is ${input.event.merchant_name} still active for you?`,
    explanation: "We found recent billing evidence, but it does not clearly confirm whether this service is still active.",
    choices: [
      { value: "yes", title: "Yes, it’s active" },
      { value: "no", title: "No, it ended" },
      { value: "not_sure", title: "Not sure" },
    ],
    priority: 90,
  };
}

export function billingCycleClarificationDraft(input: {
  event: BillingEvent;
  receivedAt: string;
  lifecycleState: MerchantLifecycleState;
  now?: number;
}): InboxClarificationDraft | null {
  if (input.lifecycleState !== "current" || input.event.billing_cycle || !recentPaidEvidence(input.event, input.receivedAt, input.now)) return null;
  return {
    kind: "billing_cycle_check",
    question: `How often do you pay for ${input.event.merchant_name}?`,
    explanation: "We found a credible recent charge, but the billing frequency was not clear.",
    choices: [
      { value: "monthly", title: "Monthly" },
      { value: "yearly", title: "Yearly" },
      { value: "not_sure", title: "Not sure" },
    ],
    priority: 70,
  };
}

export function identityClarificationDraft(input: {
  event: BillingEvent;
  receivedAt: string;
  candidateKeys: string[];
  now?: number;
}): InboxClarificationDraft | null {
  if (input.candidateKeys.length === 0 || !recentPaidEvidence(input.event, input.receivedAt, input.now)) return null;
  const choices = input.candidateKeys.slice(0, 2).map((key) => ({
    value: `same:${key}`,
    title: `It’s ${key.replace(/-/g, " ")}`,
  }));
  choices.push({ value: "different", title: "It’s a different service" }, { value: "not_sure", title: "Not sure" });
  return {
    kind: "identity_check",
    question: `Which service is “${input.event.merchant_name}”?`,
    explanation: "The billing descriptor could match more than one service you already track.",
    choices,
    priority: 80,
  };
}

export function shouldSupersedeClarification(
  kind: InboxClarificationKind,
  lifecycleState: MerchantLifecycleState,
  billingCycle: BillingCycle | null,
): boolean {
  return (kind === "lifecycle_check" && lifecycleState !== "uncertain") ||
    (kind === "billing_cycle_check" && billingCycle !== null);
}

export function isClarificationAnswerAllowed(answer: string, choices: InboxClarificationChoice[]): boolean {
  return choices.some((choice) => choice.value === answer);
}
