## Why

Answering an inbox clarification (e.g. "How often do you pay for Anthropic?" → "Monthly")
silently produces nothing: the question disappears and no candidate appears in "Needs your
review." The candidate-admission gate (`semanticValidationIssues`) requires a `renewal_date`, but a
clarified receipt has none — and nothing projects one from the cycle the user just supplied. So the
answer is dropped by a silent early-`return`, while the clarification is resolved anyway. It is a
self-defeating loop: we ask because the cycle is missing, then reject because the renewal date is
missing — a value that is derivable from the cycle we just learned.

## What Changes

- On the clarification-resolution path, once the billing cycle is known, **project `renewal_date`
  deterministically** from the last charge date + cycle instead of requiring the email to contain
  it. A subscription email is not expected to state a renewal date; it is computed.
- **Treat a user's clarification answer as confident evidence** so the auto-detection confidence
  floor (`< 0.72`) does not drop a human-confirmed candidate.
- **Never silently consume a clarification that produced no candidate.** Resolving the request must
  be conditional on a candidate actually being created (or on an explicit, recorded non-actionable
  outcome) — a silent no-op upstream must not look identical to success. This closes the class of
  bug where a future gate change could re-introduce the vanish.
- Align the candidate-admission gate with the pipeline's own completeness definition: `renewal_date`
  is **projected, not required**.

## Capabilities

### New Capabilities
- `clarification-candidate-resolution`: guarantees that answering an actionable inbox clarification
  either yields a reviewable subscription candidate (with a projected renewal date and human-level
  confidence) or leaves the clarification in a recoverable, non-vanishing state — never a silent
  drop.

### Modified Capabilities
<!-- No central specs/ capability exists to amend; behavior is captured as the new capability above. -->

## Impact

- **Code:** `supabase/functions/email-scan/index.ts` — `createCandidateFromClarification`
  (project renewal date; treat answer as confident), the resolve flow around
  `resolve_inbox_clarification_request` (make consumption conditional on outcome), and the
  `semanticValidationIssues` usage for user-clarified events. A deterministic
  renewal-projection helper (reuse the existing `projected_current_renewal` logic if present).
- **No DB schema change** — `subscription_candidates` creation already exists; this fixes the path
  that populates it. The `resolve_inbox_clarification_request` RPC is unchanged.
- **Scope note:** the live Supabase edge function is what needs this. The LangGraph worker
  (`worker/`) already sidesteps the bug (its clarify path resumes into a `present` outcome with no
  renewal-date gate), so this is the patch for the currently deployed pipeline.
- **Out of scope (follow-up):** surfacing *where* an answered item went in the UI ("Added to your
  review" / activity entry) — the "D" idea; deferred.
