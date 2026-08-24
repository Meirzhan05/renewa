-- Make resolving a clarification idempotent against retries/reopens. The outcome row is
-- unique per request_id; if a request is answered, later reopened (status set back to
-- 'open'), and answered again, the previous outcome row caused a duplicate-key violation.
-- Upserting the outcome makes re-resolution safe.
create or replace function public.resolve_inbox_clarification_request(
  p_request_id uuid,
  p_user_id uuid,
  p_answer text,
  p_effect text
)
returns table (request_id uuid, request_status text, idempotent boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  stored_status text;
begin
  select status into stored_status
  from public.inbox_clarification_requests
  where id = p_request_id and user_id = p_user_id
  for update;

  if stored_status is null then
    raise exception 'Clarification request not found';
  end if;

  if stored_status <> 'open' then
    return query select p_request_id, stored_status, true;
    return;
  end if;

  update public.inbox_clarification_requests
  set status = case when p_answer = 'not_sure' then 'dismissed' else 'answered' end,
      resolved_at = now()
  where id = p_request_id and user_id = p_user_id and status = 'open';

  insert into public.inbox_clarification_outcomes (request_id, user_id, answer, effect)
  values (p_request_id, p_user_id, p_answer, p_effect)
  on conflict (request_id) do update
    set answer = excluded.answer,
        effect = excluded.effect,
        created_at = now();

  return query select p_request_id,
    case when p_answer = 'not_sure' then 'dismissed' else 'answered' end,
    false;
end;
$$;

revoke all on function public.resolve_inbox_clarification_request(uuid, uuid, text, text) from public;
grant execute on function public.resolve_inbox_clarification_request(uuid, uuid, text, text) to service_role;
