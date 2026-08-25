-- Allow a new clarification outcome effect: 'answered_no_candidate'. The resolve path now records
-- this when a user gives an actionable answer but no candidate could be created, instead of
-- mislabeling it 'candidate_unblocked' or silently consuming the question. Widen the effect CHECK
-- constraint to include it.
alter table public.inbox_clarification_outcomes
  drop constraint if exists inbox_clarification_outcomes_effect_check;

alter table public.inbox_clarification_outcomes
  add constraint inbox_clarification_outcomes_effect_check
  check (effect in (
    'retained_uncertain',
    'dismissed',
    'alias_recorded',
    'candidate_created',
    'candidate_unblocked',
    'answered_no_candidate'
  ));
