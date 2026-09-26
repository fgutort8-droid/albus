-- Deterministic subscription ownership and verified purchase provenance.
begin;
-- This prelaunch transition requires a complete ownership history. Stop rather
-- than infer missing routes or store/app provenance for historical purchases.
lock table public.subscription_transactions in access exclusive mode;
do $$ begin
  if exists(select 1 from public.subscription_transactions) then
    raise exception 'Subscription history reconciliation is required before this migration';
  end if;
end $$;
alter table public.subscription_transactions
  add column ownership_origin_user_id uuid,
  add column ownership_origin_at timestamptz,
  add column ownership_event_at timestamptz,
  add column ownership_restore_at timestamptz,
  add column ownership_path uuid[] not null default '{}',
  add column verified_store text check (verified_store in ('APP_STORE','MAC_APP_STORE')),
  add column verified_app_id text check (length(verified_app_id) between 1 and 255);
create index subscription_ownership_path_idx on public.subscription_transactions using gin(ownership_path);

create table private.subscription_transfers (
  event_id text primary key references public.subscription_webhook_events(event_id),
  event_at timestamptz not null,
  source_ids uuid[] not null,
  destination_id uuid not null,
  -- The durable billing route survives deletion; this FK protects an existing
  -- pending destination from maintenance without preventing explicit deletion.
  active_destination_id uuid references auth.users(id) on delete set null,
  allowed_app_ids text[],
  app_id text,
  store text check (store in ('APP_STORE','MAC_APP_STORE')),
  environment text check (environment in ('Production','Sandbox'))
);
alter table private.subscription_transfers enable row level security;
revoke all on private.subscription_transfers from public,anon,authenticated;
create index subscription_transfers_order_idx on private.subscription_transfers(event_at,event_id);
create index subscription_transfers_destination_idx on private.subscription_transfers(active_destination_id);

create or replace function private.reconcile_subscription_ownership(p_original_id text)
returns integer language plpgsql security definer set search_path='' as $$
declare
  s public.subscription_transactions%rowtype;
  e private.subscription_transfers%rowtype;
  v_owner uuid;
  v_materialized uuid;
  v_path uuid[];
  v_at timestamptz;
  v_user uuid;
begin
  select * into s from public.subscription_transactions where original_transaction_id=p_original_id;
  if not found then return 0; end if;
  if s.ownership_origin_user_id is null then
    if s.user_id is null then return 0; end if;
    s.ownership_origin_user_id := s.user_id;
    s.ownership_origin_at := coalesce(s.last_event_at,s.created_at);
    update public.subscription_transactions set ownership_origin_user_id=s.user_id,
      ownership_origin_at=s.ownership_origin_at where original_transaction_id=p_original_id;
  end if;
  v_owner := s.ownership_origin_user_id;
  v_path := array[v_owner];
  v_at := s.ownership_origin_at;
  for e in select * from private.subscription_transfers
    where event_at >= s.ownership_origin_at order by event_at,event_id
  loop
    if v_owner=any(e.source_ids)
      and (e.allowed_app_ids is null or (s.verified_app_id=any(e.allowed_app_ids) and s.verified_store in ('APP_STORE','MAC_APP_STORE')))
      and (e.app_id is null or e.app_id=s.verified_app_id)
      and (e.store is null or e.store=s.verified_store)
      and (e.environment is null or e.environment=s.environment) then
      v_owner := e.destination_id;
      v_at := e.event_at;
      v_path := array_append(v_path,v_owner);
    end if;
  end loop;
  -- NOWAIT yields to explicit deletion and permits webhook retry, avoiding a
  -- lock inversion with the auth cascade while preserving every live owner.
  perform 1 from auth.users where id in (s.user_id,v_owner) order by id for key share nowait;
  select id into v_materialized from auth.users where id=v_owner;
  if s.user_id is distinct from v_materialized then
    for v_user in select distinct u from unnest(array[s.user_id,v_materialized]) u where u is not null order by u loop
      perform pg_advisory_xact_lock(hashtextextended('albus:subscription-owner:'||v_user::text,0));
    end loop;
    update public.subscription_transactions set user_id=v_materialized,updated_at=now()
      where original_transaction_id=p_original_id;
    if s.user_id is not null and v_materialized is not null then
      perform pg_advisory_xact_lock(hashtextextended('albus:ai_usage:global',0));
      for v_user in select distinct u from unnest(array[s.user_id,v_materialized]) u order by u loop
        perform pg_advisory_xact_lock(hashtextextended('albus:ai_usage:'||v_user::text,0));
      end loop;
      update public.ai_usage set user_id=v_materialized
        where user_id=s.user_id and created_at>now()-interval '30 days';
    end if;
    perform private.recompute_entitlement(s.user_id);
    perform private.recompute_entitlement(v_materialized);
  end if;
  update public.subscription_transactions set ownership_path=v_path,ownership_event_at=v_at
    where original_transaction_id=p_original_id;
  return case when s.user_id is distinct from v_materialized then 1 else 0 end;
end;
$$;
revoke all on function private.reconcile_subscription_ownership(text) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION private.apply_subscription_event(p_original_transaction_id text, p_user_id uuid, p_latest_transaction_id text, p_product_id text, p_environment text, p_purchase_date timestamp with time zone, p_expires_at timestamp with time zone, p_revoked_at timestamp with time zone, p_event_id text, p_event_at timestamp with time zone, p_store text, p_app_id text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_existing public.subscription_transactions%rowtype;
  v_had_existing boolean := false;
  v_conflict boolean := false;
  v_owner uuid;
  v_product text;
  v_tier text;
  v_result text;
begin
  if p_original_transaction_id is null or length(p_original_transaction_id) > 255
     or p_event_id is null or length(p_event_id) > 255
     or p_event_at is null
     or p_environment not in ('Production', 'Sandbox') then
    return 'invalid';
  end if;

  if p_environment = 'Sandbox'
     and coalesce((select c.int_value from public.app_config c
                    where c.key = 'allow_sandbox_subscriptions'), 0) <> 1 then
    return 'sandbox_ignored';
  end if;

  if (p_store is null) <> (p_app_id is null)
     or (p_store is not null and (p_store not in ('APP_STORE','MAC_APP_STORE') or length(p_app_id) not between 1 and 255)) then
    return 'invalid';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('albus:subscription:ownership',0));
  perform 1 from auth.users where id = p_user_id for key share nowait;

  perform pg_advisory_xact_lock(
    hashtextextended('albus:subscription:' || p_original_transaction_id, 0));

  select * into v_existing
    from public.subscription_transactions s
   where s.original_transaction_id = p_original_transaction_id;
  v_had_existing := found;
  if v_had_existing and p_app_id is not null
     and ((v_existing.verified_app_id is not null and v_existing.verified_app_id <> p_app_id)
          or (v_existing.verified_store is not null and v_existing.verified_store <> p_store)) then
    return 'conflict';
  end if;
  perform 1 from auth.users where id = v_existing.user_id for key share nowait;
  if v_had_existing and v_existing.verified_store is not null and v_existing.environment <> p_environment then
    return 'conflict';
  end if;

  -- Older billing facts can supply the earliest observed ownership origin.
  -- A confirmed restore after deletion is a barrier against old receipts.
  if v_had_existing and p_user_id is not null
     and p_event_at < v_existing.ownership_origin_at
     and p_event_at >= coalesce(v_existing.ownership_restore_at,'-infinity'::timestamptz) then
    update public.subscription_transactions set ownership_origin_user_id=p_user_id,
      ownership_origin_at=p_event_at where original_transaction_id=p_original_transaction_id;
    perform private.reconcile_subscription_ownership(p_original_transaction_id);
  end if;

  -- A later verified restore may bind a purchase whose previous account was
  -- explicitly deleted. Older receipts cannot replace newer ownership events.
  if v_had_existing and v_existing.user_id is null and p_user_id is not null
     and p_event_at > coalesce(v_existing.ownership_event_at, '-infinity'::timestamptz)
     and exists(select 1 from auth.users where id=p_user_id) then
    update public.subscription_transactions set ownership_origin_user_id=p_user_id,
      ownership_origin_at=p_event_at, ownership_restore_at=p_event_at, ownership_path=array[p_user_id]
    where original_transaction_id=p_original_transaction_id;
    perform private.reconcile_subscription_ownership(p_original_transaction_id);
    select * into v_existing from public.subscription_transactions
      where original_transaction_id=p_original_transaction_id;
  end if;

  if v_had_existing and v_existing.last_event_at is not null
     and (p_event_at < v_existing.last_event_at
          or p_event_id = v_existing.last_event_id) then
    -- A retry after the handler upgrade can establish provenance for a receipt
    -- already recorded by the preceding handler, without reapplying its facts.
    if p_app_id is not null and v_existing.verified_app_id is null then
      update public.subscription_transactions set verified_store=p_store,verified_app_id=p_app_id
        where original_transaction_id=p_original_transaction_id;
      perform private.reconcile_subscription_ownership(p_original_transaction_id);
    end if;
    return 'stale';
  end if;

  -- An account owns a subscription from the first event that names it until a
  -- signed TRANSFER moves it. An event naming another account still carries
  -- true facts about the subscription -- RevenueCat can deliver a restored
  -- purchase's renewal before the transfer that explains it -- so the facts
  -- are kept for the current owner and the other account is granted nothing.
  v_conflict := v_had_existing and v_existing.user_id is not null
                and p_user_id is not null and v_existing.user_id <> p_user_id;
  v_owner := coalesce(v_existing.user_id, p_user_id);

  -- One account can briefly own more than one transaction during an upgrade,
  -- cross-platform purchase, or billing retry. Events are ordered per original
  -- transaction, but entitlement is one row per *user*, so transactions for
  -- the same user must also serialize. Without this lock two valid webhooks
  -- can each recompute from a different snapshot and let the last writer
  -- downgrade a still-active Pro account to Plus or Free.
  if v_owner is not null then
    perform pg_advisory_xact_lock(
      hashtextextended('albus:subscription-owner:' || v_owner::text, 0));
  end if;

  v_product := coalesce(nullif(p_product_id, ''), v_existing.product_id);
  select sp.tier into v_tier
    from public.subscription_products sp
   where sp.product_id = v_product and sp.active;

  -- Removing a product from sale prevents *new* transactions from granting it;
  -- it must not invalidate an already verified subscriber. Existing renewals
  -- and revocations therefore keep the stored mapping even after retirement.
  if v_tier is null and v_had_existing and v_product = v_existing.product_id then
    select sp.tier into v_tier
      from public.subscription_products sp
     where sp.product_id = v_existing.product_id;
  end if;
  if v_tier is null then return 'unknown_product'; end if;

  insert into public.subscription_transactions (
    original_transaction_id, user_id, latest_transaction_id, product_id,
    environment, purchase_date, expires_at, revoked_at,
    last_event_id, last_event_at, updated_at
  ) values (
    p_original_transaction_id, v_owner, p_latest_transaction_id, v_product,
    p_environment, p_purchase_date, p_expires_at, p_revoked_at,
    p_event_id, p_event_at, now()
  )
  on conflict (original_transaction_id) do update set
    user_id = coalesce(public.subscription_transactions.user_id, excluded.user_id),
    latest_transaction_id = excluded.latest_transaction_id,
    product_id = coalesce(excluded.product_id, public.subscription_transactions.product_id),
    environment = excluded.environment,
    purchase_date = excluded.purchase_date,
    expires_at = excluded.expires_at,
    revoked_at = excluded.revoked_at,
    last_event_id = excluded.last_event_id,
    last_event_at = excluded.last_event_at,
    updated_at = now();

  update public.subscription_transactions s set
    ownership_origin_user_id = coalesce(s.ownership_origin_user_id, v_owner),
    ownership_origin_at = coalesce(s.ownership_origin_at, p_event_at),
    ownership_path = case when cardinality(s.ownership_path)=0 and v_owner is not null then array[v_owner] else s.ownership_path end,
    verified_store = coalesce(s.verified_store, p_store),
    verified_app_id = coalesce(s.verified_app_id, p_app_id)
  where s.original_transaction_id = p_original_transaction_id;

  perform private.reconcile_subscription_ownership(p_original_transaction_id);
  select s.user_id into v_owner from public.subscription_transactions s
    where s.original_transaction_id=p_original_transaction_id;
  if v_owner is null then return 'unlinked'; end if;

  v_result := private.recompute_entitlement(v_owner);
  return case when v_conflict then 'conflict' else v_result end;
end;
$function$;
CREATE OR REPLACE FUNCTION public.apply_subscription_state(p_original_transaction_id text, p_user_id uuid, p_latest_transaction_id text, p_product_id text, p_environment text, p_purchase_date timestamp with time zone, p_expires_at timestamp with time zone, p_revoked_at timestamp with time zone, p_event_id text, p_event_at timestamp with time zone)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  return private.apply_subscription_event(p_original_transaction_id,p_user_id,p_latest_transaction_id,p_product_id,
    p_environment,p_purchase_date,p_expires_at,p_revoked_at,p_event_id,p_event_at,null,null);
end;
$function$;

CREATE OR REPLACE FUNCTION public.apply_verified_subscription_state(p_original_transaction_id text, p_user_id uuid, p_latest_transaction_id text, p_product_id text, p_environment text, p_purchase_date timestamp with time zone, p_expires_at timestamp with time zone, p_revoked_at timestamp with time zone, p_event_id text, p_event_at timestamp with time zone, p_store text, p_app_id text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_store is null or p_app_id is null then return 'invalid'; end if;
  return private.apply_subscription_event(p_original_transaction_id,p_user_id,p_latest_transaction_id,p_product_id,
    p_environment,p_purchase_date,p_expires_at,p_revoked_at,p_event_id,p_event_at,p_store,p_app_id);
end;
$function$;


create function private.apply_subscription_transfer(p_from uuid[],p_to uuid,p_event_id text,p_event_at timestamptz,
  p_allowed_app_ids text[],p_app_id text,p_store text,p_environment text)
returns text language plpgsql security definer set search_path='' as $$
declare v_id text; v_moved integer:=0; v_user uuid; v_active_destination uuid;
begin
  if p_to is null or p_event_at is null or p_event_id is null or length(p_event_id) not between 1 and 255
    or (p_allowed_app_ids is not null and cardinality(p_allowed_app_ids)=0)
    or (p_app_id is not null and p_allowed_app_ids is not null and not p_app_id=any(p_allowed_app_ids))
    or (p_store is not null and p_store not in ('APP_STORE','MAC_APP_STORE'))
    or (p_environment is not null and p_environment not in ('Production','Sandbox')) then return 'invalid'; end if;
  -- Protect the destination before waiting for subscription work.
  select id into v_active_destination from auth.users where id=p_to for key share;
  -- Verified delivery may supply a historical hop through a deleted account.
  -- Keep its route without granting a nonexistent account any entitlement.
  -- The legacy service contract still rejects absent destinations.
  if v_active_destination is null and p_allowed_app_ids is null then return 'invalid'; end if;
  perform pg_advisory_xact_lock(hashtextextended('albus:subscription:ownership',0));
  insert into public.subscription_webhook_events(event_id,event_type) values(p_event_id,'TRANSFER')
    on conflict(event_id) do nothing;
  if not found then return 'stale'; end if;
  insert into private.subscription_transfers(event_id,event_at,source_ids,destination_id,active_destination_id,allowed_app_ids,app_id,store,environment)
    values(p_event_id,p_event_at,coalesce(p_from,'{}'::uuid[]),p_to,v_active_destination,p_allowed_app_ids,p_app_id,p_store,p_environment);
  for v_id in select original_transaction_id from public.subscription_transactions
    where ownership_path && coalesce(p_from,'{}'::uuid[]) or user_id=any(p_from)
    order by original_transaction_id
  loop
    perform pg_advisory_xact_lock(hashtextextended('albus:subscription:'||v_id,0));
    v_moved := v_moved+private.reconcile_subscription_ownership(v_id);
  end loop;
  -- Preserve durable plan history even for a transfer arriving before a purchase.
  for v_user in select distinct u from unnest(array_append(coalesce(p_from,'{}'::uuid[]),p_to)) u where u is not null order by u loop
    perform 1 from auth.users where id=v_user for key share nowait;
    perform pg_advisory_xact_lock(hashtextextended('albus:subscription-owner:'||v_user::text,0));
    perform private.recompute_entitlement(v_user);
  end loop;
  return case when v_moved>0 then 'transferred' else 'nothing_to_transfer' end;
end;
$$;
revoke all on function private.apply_subscription_transfer(uuid[],uuid,text,timestamptz,text[],text,text,text) from public,anon,authenticated;

create or replace function public.transfer_subscriptions(p_from uuid[],p_to uuid,p_event_id text,p_event_at timestamptz)
returns text language plpgsql security definer set search_path='' as $$
begin
  return private.apply_subscription_transfer(p_from,p_to,p_event_id,p_event_at,null,null,null,null);
end;
$$;
create function public.transfer_verified_subscriptions(p_from uuid[],p_to uuid,p_event_id text,p_event_at timestamptz,
  p_allowed_app_ids text[],p_app_id text default null,p_store text default null,p_environment text default null)
returns text language plpgsql security definer set search_path='' as $$
begin
  if p_allowed_app_ids is null then return 'invalid'; end if;
  return private.apply_subscription_transfer(p_from,p_to,p_event_id,p_event_at,p_allowed_app_ids,p_app_id,p_store,p_environment);
end;
$$;

revoke all on function private.apply_subscription_event(text,uuid,text,text,text,timestamptz,timestamptz,timestamptz,text,timestamptz,text,text) from public,anon,authenticated;

revoke all on function public.apply_subscription_state(text,uuid,text,text,text,timestamptz,timestamptz,timestamptz,text,timestamptz) from public,anon,authenticated;
grant execute on function public.apply_subscription_state(text,uuid,text,text,text,timestamptz,timestamptz,timestamptz,text,timestamptz) to service_role;

revoke all on function public.apply_verified_subscription_state(text,uuid,text,text,text,timestamptz,timestamptz,timestamptz,text,timestamptz,text,text) from public,anon,authenticated;
grant execute on function public.apply_verified_subscription_state(text,uuid,text,text,text,timestamptz,timestamptz,timestamptz,text,timestamptz,text,text) to service_role;

revoke all on function public.transfer_subscriptions(uuid[],uuid,text,timestamptz) from public,anon,authenticated;
grant execute on function public.transfer_subscriptions(uuid[],uuid,text,timestamptz) to service_role;

revoke all on function public.transfer_verified_subscriptions(uuid[],uuid,text,timestamptz,text[],text,text,text) from public,anon,authenticated;
grant execute on function public.transfer_verified_subscriptions(uuid[],uuid,text,timestamptz,text[],text,text,text) to service_role;


create table private.ai_usage_purchases (
  usage_id uuid not null references public.ai_usage(id) on delete cascade,
  original_transaction_id text not null references public.subscription_transactions(original_transaction_id) on delete cascade,
  primary key(usage_id,original_transaction_id)
);
alter table private.ai_usage_purchases enable row level security;
revoke all on private.ai_usage_purchases from public,anon,authenticated;
create index ai_usage_purchases_transaction_idx on private.ai_usage_purchases(original_transaction_id);

create function private.link_purchase_usage(p_uid uuid)
returns void language sql security definer set search_path='' as $$
  insert into private.ai_usage_purchases(usage_id,original_transaction_id)
    select u.id,s.original_transaction_id from public.ai_usage u
    join public.subscription_transactions s on s.user_id=p_uid
    where (u.user_id=p_uid or exists (
      select 1 from private.ai_usage_purchases prior_link
      join public.subscription_transactions prior_purchase
        on prior_purchase.original_transaction_id=prior_link.original_transaction_id
      where prior_link.usage_id=u.id and prior_purchase.user_id=p_uid))
      and u.created_at>now()-interval '30 days'
    on conflict do nothing;
$$;
revoke all on function private.link_purchase_usage(uuid) from public,anon,authenticated;

create function private.track_purchase_usage()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('albus:ai_usage:global',0));
  if tg_table_name='subscription_transactions' then
    if tg_when='BEFORE' then
      perform private.link_purchase_usage(old.user_id);
    else
      perform private.link_purchase_usage(new.user_id);
    end if;
  elsif new.user_id is not null then
    insert into private.ai_usage_purchases(usage_id,original_transaction_id)
      select new.id,s.original_transaction_id from public.subscription_transactions s
      where s.user_id=new.user_id and new.created_at>now()-interval '30 days'
      on conflict do nothing;
  end if;
  return new;
end;
$$;
revoke all on function private.track_purchase_usage() from public,anon,authenticated;
create trigger purchase_usage_before before update of user_id on public.subscription_transactions
  for each row execute function private.track_purchase_usage();
create trigger purchase_usage_after after insert or update of user_id on public.subscription_transactions
  for each row execute function private.track_purchase_usage();
create trigger usage_purchase_after after insert or update of user_id on public.ai_usage
  for each row execute function private.track_purchase_usage();

create or replace function private.ai_account_cost(
  p_uid uuid,
  p_since interval
) returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  -- A terminal call with provider usage pays its measured, server-priced cost.
  -- Anything unfinished or unknown keeps the conservative reservation. A
  -- crashed isolate therefore cannot turn an Anthropic call into free budget.
  select coalesce(sum(
    case
      when u.attempt_state = 'reserved' then u.reserved_cost_microusd
      when u.actual_cost_microusd is not null then u.actual_cost_microusd
      else u.reserved_cost_microusd
    end
  ), 0)::bigint
  from public.ai_usage u
  where (u.user_id = p_uid or exists (
       select 1 from private.ai_usage_purchases l
       join public.subscription_transactions s on s.original_transaction_id=l.original_transaction_id
       where l.usage_id=u.id and s.user_id=p_uid))
    and u.created_at > now() - p_since;
$$;

revoke all on function private.ai_account_cost(uuid, interval)
  from public, anon, authenticated;

create or replace function private.ai_attempt_count(
  p_uid uuid,
  p_kind text,
  p_since interval
) returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer
    from public.ai_usage u
   where (u.user_id = p_uid or exists (
       select 1 from private.ai_usage_purchases l
       join public.subscription_transactions s on s.original_transaction_id=l.original_transaction_id
       where l.usage_id=u.id and s.user_id=p_uid))
     and u.kind = p_kind
     and u.created_at > now() - p_since;
$$;

revoke all on function private.ai_attempt_count(uuid, text, interval)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Allowance means delivered result; rate means every attempt

create or replace function public.ai_spend_count(
  p_uid uuid,
  p_kind text,
  p_since interval
) returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer
    from public.ai_usage u
   where (u.user_id = p_uid or exists (
       select 1 from private.ai_usage_purchases l
       join public.subscription_transactions s on s.original_transaction_id=l.original_transaction_id
       where l.usage_id=u.id and s.user_id=p_uid))
     and u.kind = p_kind
     and u.created_at > now() - p_since
     and (
          u.attempt_state = 'completed'
       or (u.attempt_state = 'reserved'
           and u.created_at > now() - interval '15 minutes')
     );
$$;

comment on function public.ai_spend_count(uuid, text, interval) is
  'Successful results plus genuinely in-flight reservations. Failed attempts do not consume a purchased allowance.';

revoke all on function public.ai_spend_count(uuid, text, interval)
  from public, anon, authenticated;

create or replace function public.ai_window_resets_at(
  p_uid uuid,
  p_kind text,
  p_since interval
) returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select min(u.created_at) + p_since
    from public.ai_usage u
   where (u.user_id = p_uid or exists (
       select 1 from private.ai_usage_purchases l
       join public.subscription_transactions s on s.original_transaction_id=l.original_transaction_id
       where l.usage_id=u.id and s.user_id=p_uid))
     and u.kind = p_kind
     and u.created_at > now() - p_since
     and (
          u.attempt_state = 'completed'
       or (u.attempt_state = 'reserved'
           and u.created_at > now() - interval '15 minutes')
     );
$$;

revoke all on function public.ai_window_resets_at(uuid, text, interval)
  from public, anon, authenticated;


CREATE OR REPLACE FUNCTION public.check_and_record_ai_usage(p_user_id uuid, p_kind text, p_model text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_plan          public.plans%rowtype;
  v_pool          text;
  v_allow_limit   integer;
  v_allow_window  interval;
  v_used          integer;
  v_hour_limit    integer;
  v_day_limit     integer;
  v_model         text;
  v_global_cap    integer;
  v_global_used   integer;
  v_hour_budget   bigint;
  v_day_budget    bigint;
  v_hour_spend    bigint;
  v_day_spend     bigint;
  v_reservation   integer;
  v_account_budget bigint;
  v_account_spend  bigint;
  v_emergency     boolean;
  v_band          text;
  v_divisor       integer := 1;
  v_verify_on     boolean;
  v_anonymous     boolean;
  v_id            uuid;
begin
  perform 1 from auth.users where id=p_user_id for key share;
  if not found then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;
  if p_kind not in ('breakdown', 'chat', 'grade') then
    raise exception 'INVALID_KIND' using errcode = '22023';
  end if;

  v_model := left(coalesce(p_model, 'unknown'), 64);
  if v_model !~ '^[A-Za-z0-9._-]+$' then v_model := 'unknown'; end if;
  v_reservation := private.ai_reservation_cost(p_kind, v_model);

  -- Global first, user second, everywhere. The short global lock closes the
  -- thousand-account race on both the call fuse and monetary budget. Holding
  -- locks in one order prevents deadlocks.
  perform pg_advisory_xact_lock(hashtextextended('albus:ai_usage:global', 0));
  perform pg_advisory_xact_lock(
    hashtextextended('albus:ai_usage:' || p_user_id::text, 0));

  select coalesce(max(case when key = 'ai_emergency_stop' then int_value end), 0) = 1,
         coalesce(max(case when key = 'global_ai_calls_per_hour' then int_value end), 100)
    into v_emergency, v_global_cap
    from public.app_config;

  if v_emergency then
    raise exception 'AI_EMERGENCY_STOP' using errcode = 'Q0013';
  end if;

  -- The caller's plan decides which fuse the call burns. Free accounts cost
  -- nothing to create, so they share one fuse and paying accounts another:
  -- however many free accounts appear, they cannot use up what paying
  -- students need.
  select p.* into v_plan
    from public.plans p where p.tier = public.effective_tier(p_user_id);
  if not found then raise exception 'PLAN_UNKNOWN' using errcode = 'Q0005'; end if;
  v_pool := case when v_plan.tier = 'free' then 'free' else 'paid' end;

  select b.hour_budget, b.day_budget into v_hour_budget, v_day_budget
    from private.ai_pool_budget(v_pool) b;

  select count(*) into v_global_used
    from public.ai_usage u
   where u.created_at > now() - interval '1 hour'
     and u.budget_pool = v_pool;
  v_hour_spend := private.ai_pool_cost(v_pool, interval '1 hour');

  if v_global_used >= v_global_cap
     or v_hour_spend + v_reservation > v_hour_budget then
    raise exception 'GLOBAL_CAPACITY_REACHED' using errcode = 'Q0004';
  end if;

  v_day_spend := private.ai_pool_cost(v_pool, interval '1 day');

  if v_day_spend + v_reservation > v_day_budget then
    raise exception 'GLOBAL_CAPACITY_REACHED' using errcode = 'Q0004';
  end if;

  select r.band into v_band from public.account_risk(p_user_id) r;
  v_band := coalesce(v_band, 'normal');
  if v_band = 'severe' then
    raise exception 'ABUSE_SUSPECTED' using errcode = 'Q0010';
  end if;

  if v_band = 'high' then
    select coalesce(c.int_value, 0) = 1 into v_verify_on
      from public.app_config c where c.key = 'risk_verification_available';
    select u.is_anonymous into v_anonymous from auth.users u where u.id = p_user_id;
    if coalesce(v_verify_on, false) and coalesce(v_anonymous, false) then
      raise exception 'VERIFICATION_REQUIRED' using errcode = 'Q0009';
    end if;
  end if;
  v_divisor := case v_band when 'high' then 4 when 'elevated' then 2 else 1 end;

  if p_kind = 'chat' then
    v_allow_limit := v_plan.chat_per_month;
    v_allow_window := interval '30 days';
  elsif p_kind = 'grade' then
    v_allow_limit := v_plan.grade_per_week;
    v_allow_window := interval '7 days';
  else
    v_allow_limit := v_plan.breakdown_per_week;
    v_allow_window := interval '7 days';
  end if;

  if v_allow_limit = 0 then
    raise exception 'PLAN_UPGRADE_REQUIRED' using errcode = 'Q0007';
  elsif v_allow_limit is not null then
    v_used := public.ai_spend_count(p_user_id, p_kind, v_allow_window);
    if v_used >= v_allow_limit then
      if p_kind = 'chat' then
        raise exception 'ALLOWANCE_MONTHLY' using errcode = 'Q0008';
      else
        raise exception 'ALLOWANCE_WEEKLY' using errcode = 'Q0006';
      end if;
    end if;
  end if;

  -- Check cost only after entitlement. A Free account asking for Grader must
  -- hear that Grader is not on Free even if it has also spent its planning
  -- budget; reversing these checks turns an upgrade decision into a vague
  -- operational refusal.
  select b.rolling_30d_cost_microusd into v_account_budget
    from private.ai_tier_budgets b where b.tier = v_plan.tier;
  if v_account_budget is null then
    -- Missing safety configuration must fail closed. Treating it as unlimited
    -- would make a new tier or a bad deployment an unmetered provider path.
    raise exception 'AI_BUDGET_UNKNOWN' using errcode = 'Q0017';
  end if;

  v_account_spend := private.ai_account_cost(
    p_user_id, interval '30 days');
  if v_account_spend + v_reservation > v_account_budget then
    raise exception 'FAIR_USE_REACHED' using errcode = 'Q0017';
  end if;

  if p_kind = 'chat' then
    v_hour_limit := v_plan.chat_per_hour;
    v_day_limit := v_plan.chat_per_day;
  elsif p_kind = 'grade' then
    v_hour_limit := v_plan.grade_per_hour;
    v_day_limit := null;
  else
    v_hour_limit := v_plan.breakdown_per_hour;
    v_day_limit := v_plan.breakdown_per_day;
  end if;

  if v_divisor > 1 then
    if v_hour_limit is not null and v_hour_limit > 0 then
      v_hour_limit := greatest(1, v_hour_limit / v_divisor);
    end if;
    if v_day_limit is not null and v_day_limit > 0 then
      v_day_limit := greatest(1, v_day_limit / v_divisor);
    end if;
  end if;

  -- Every reservation is an attempt, including a provider failure. That makes
  -- retries finite even though failed results do not consume the allowance.
  if v_hour_limit is not null
     and private.ai_attempt_count(p_user_id, p_kind, interval '1 hour') >= v_hour_limit then
    raise exception 'RATE_LIMIT_HOURLY' using errcode = 'Q0002';
  end if;
  if v_day_limit is not null
     and private.ai_attempt_count(p_user_id, p_kind, interval '1 day') >= v_day_limit then
    raise exception 'RATE_LIMIT_DAILY' using errcode = 'Q0003';
  end if;

  insert into public.ai_usage
    (user_id, kind, model, attempt_state, reserved_cost_microusd, budget_pool)
  values
    (p_user_id, p_kind, v_model, 'reserved', v_reservation, v_pool)
  returning id into v_id;
  return v_id;
end;
$function$;
create or replace function public.prune_security_data(
  p_link_days integer default 90,
  p_event_days integer default 180
) returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_links integer;
  v_events integer;
  v_attempts integer;
  v_windows integer;
  v_purchase_links integer;
begin
  delete from public.identity_links
   where last_seen_at < now() - make_interval(days => greatest(30, p_link_days));
  get diagnostics v_links = row_count;
  delete from public.security_events
   where at < now() - make_interval(days => greatest(30, p_event_days));
  get diagnostics v_events = row_count;
  delete from public.ai_usage
   where attempt_state in ('failed', 'reserved')
     and created_at < now() - interval '30 days';
  get diagnostics v_attempts = row_count;
  delete from private.api_rate_windows
   where window_start < now() - interval '2 hours';
  get diagnostics v_windows = row_count;
  delete from private.ai_usage_purchases l using public.ai_usage u
   where l.usage_id=u.id and u.created_at <= now()-interval '30 days';
  get diagnostics v_purchase_links = row_count;
  return v_links + v_events + v_attempts + v_windows + v_purchase_links;
end;
$$;
revoke all on function public.prune_security_data(integer, integer)
  from public, anon, authenticated;


commit;
