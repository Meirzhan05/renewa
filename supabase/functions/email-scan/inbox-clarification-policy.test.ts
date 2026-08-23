import {
  billingCycleClarificationDraft,
  identityClarificationDraft,
  isClarificationAnswerAllowed,
  lifecycleClarificationDraft,
  shouldSupersedeClarification,
} from "../_shared/inbox-clarification-policy.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

const recentEvent = {
  message_id: "receipt-1",
  event_type: "renewed" as const,
  merchant_name: "ChatGPT",
  amount: 20,
  currency: "USD",
  billing_cycle: null,
  event_date: "2026-08-20",
  renewal_date: "2026-09-20",
  category: "work" as const,
  confidence: 0.94,
  evidence: "A monthly service charge was found.",
};
const now = Date.parse("2026-08-22T00:00:00Z");
const receivedAt = "2026-08-20T00:00:00Z";

Deno.test("recent uncertain paid evidence creates a bounded lifecycle question", () => {
  const draft = lifecycleClarificationDraft({
    event: recentEvent,
    receivedAt,
    lifecycleState: "uncertain",
    now,
  });
  assert(draft?.kind === "lifecycle_check", "expected lifecycle clarification");
  assert(isClarificationAnswerAllowed("not_sure", draft?.choices ?? []), "Not sure must be safe");
});

Deno.test("weak, stale, and marketing-like evidence does not create a clarification", () => {
  assert(
    lifecycleClarificationDraft({
      event: { ...recentEvent, confidence: 0.5 },
      receivedAt,
      lifecycleState: "uncertain",
      now,
    }) === null,
    "low confidence should stay quiet",
  );
  assert(
    lifecycleClarificationDraft({
      event: recentEvent,
      receivedAt: "2025-01-01T00:00:00Z",
      lifecycleState: "uncertain",
      now,
    }) === null,
    "stale evidence should stay quiet",
  );
  assert(
    lifecycleClarificationDraft({
      event: { ...recentEvent, event_type: "trial_started" },
      receivedAt,
      lifecycleState: "uncertain",
      now,
    }) === null,
    "non-paid trial signals should stay quiet",
  );
});

Deno.test("identity and billing cycle questions stay bounded", () => {
  const identity = identityClarificationDraft({
    event: recentEvent,
    receivedAt,
    candidateKeys: ["openai", "chatgpt"],
    now,
  });
  const cycle = billingCycleClarificationDraft({
    event: recentEvent,
    receivedAt,
    lifecycleState: "current",
    now,
  });
  assert(identity?.choices.length === 4, "identity answers should be bounded");
  assert(cycle?.choices.map((choice) => choice.value).includes("monthly") === true, "cycle must offer a cycle answer");
  assert(
    shouldSupersedeClarification("lifecycle_check", "current", null),
    "new lifecycle evidence should supersede lifecycle uncertainty",
  );
});
