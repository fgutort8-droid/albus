begin;

-- Account cleanup (reap_abandoned_anonymous_users) locks each candidate's
-- auth.users row FOR UPDATE SKIP LOCKED and spares any it cannot lock, then
-- spares any account named in a user_id column. Enqueueing named the account
-- only when its insert committed, so a cleanup that checked the inbox a moment
-- earlier could still remove the account a payment was arriving for. Holding
-- the account's row while the event is recorded closes that gap: cleanup skips
-- an account being paid for, and an event for an account cleanup already
-- removed is recorded without one, as revenue already is.
create or replace function public.enqueue_revenuecat_event(p_scope text,p_event_id text,p_payload jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_hash text; v_existing text; v_user text;
begin
  if p_scope is null or length(p_scope) not between 1 and 2048 or p_event_id is null
    or length(p_event_id) not between 1 and 255 or p_payload is null
    or octet_length(p_payload::text)>16384
    or coalesce(p_payload->>'operation','') not in ('subscription','transfer')
    or (p_payload - array['operation','subscription','transfer','revenue']) <> '{}'::jsonb
    or coalesce(p_payload#>>'{subscription,p_event_id}',p_payload#>>'{transfer,p_event_id}','')<>p_event_id
    or (p_payload ? 'revenue' and coalesce(p_payload#>>'{revenue,p_event_id}','')<>p_event_id) then
    raise exception 'INVALID_FINANCIAL_EVENT' using errcode='22023';
  end if;
  v_hash := encode(extensions.digest(p_payload::text,'sha256'),'hex');
  -- The account it would benefit: the subscriber, or a transfer's destination.
  v_user := coalesce(p_payload#>>'{subscription,p_user_id}',p_payload#>>'{transfer,p_to}');
  if v_user !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then v_user := null; end if;
  if v_user is not null then
    -- Held until this transaction commits, when the inbox row naming it is
    -- visible to cleanup. A row cleanup holds is waited for, not skipped.
    perform 1 from auth.users u where u.id = v_user::uuid for key share;
    if not found then v_user := null; end if;
  end if;
  insert into private.financial_inbox(scope,event_id,payload,payload_hash,user_id)
    values(p_scope,p_event_id,p_payload,v_hash,v_user::uuid) on conflict(provider,scope,event_id) do nothing
    returning id into v_id;
  if v_id is null then
    select id,payload_hash into v_id,v_existing from private.financial_inbox
      where provider='revenuecat' and scope=p_scope and event_id=p_event_id;
    if v_existing<>v_hash then raise exception 'FINANCIAL_EVENT_ID_REUSED' using errcode='22023'; end if;
  end if;
  return v_id;
end $$;
revoke all on function public.enqueue_revenuecat_event(text,text,jsonb) from public,anon,authenticated;
grant execute on function public.enqueue_revenuecat_event(text,text,jsonb) to service_role;

commit;
