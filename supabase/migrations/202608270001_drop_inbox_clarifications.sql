-- Remove the inbox clarification feature. The scanner no longer asks the person mid-scan
-- clarifying questions ("is this still active?", "monthly or yearly?"); a verified, confident
-- merchant is now surfaced directly as a candidate the person confirms, and unresolved-identity
-- or under-evidenced merchants are simply withheld. This drops the now-orphaned request/outcome
-- tables and the resolve RPC. The data was transient (30-day expiry) with no downstream consumers.
--
-- Superseded migrations (kept for history, no longer applied to fresh DBs):
--   202608220002_inbox_clarification_requests.sql
--   202608230004_resolve_clarification_idempotent.sql
--   202608240001_clarification_effect_answered_no_candidate.sql
--   202608250001_resolve_clarification_unambiguous_request_id.sql

drop function if exists public.resolve_inbox_clarification_request(uuid, uuid, text, text);

-- CASCADE clears the indexes, RLS policies, and the updated_at trigger defined on these tables.
drop table if exists public.inbox_clarification_outcomes cascade;
drop table if exists public.inbox_clarification_requests cascade;
