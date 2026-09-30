begin;

-- Private durable work and immutable evidence. No raw webhook bodies or secrets.
create table private.financial_inbox (
  id uuid primary key default gen_random_uuid(),
  provider text not null default 'revenuecat' check (provider = 'revenuecat'),
  scope text not null check (length(scope) between 1 and 2048),
  event_id text not null check (length(event_id) between 1 and 255),
  payload jsonb not null check (octet_length(payload::text) <= 16384),
  payload_hash text not null,
  state text not null default 'pending' check (state in ('pending','retry','completed','dead')),
  attempts integer not null default 0,
  received_at timestamptz not null default now(),
  available_at timestamptz not null default now(),
  completed_at timestamptz,
  result text,
  error_code text,
  unique(provider,scope,event_id)
);
create index financial_inbox_pending_idx on private.financial_inbox(available_at,received_at)
  where state in ('pending','retry');
alter table private.financial_inbox enable row level security;
revoke all on private.financial_inbox from public,anon,authenticated,service_role;

create table private.financial_audit (
  id uuid primary key default gen_random_uuid(),
  occurred_at timestamptz not null default clock_timestamp(),
  actor text not null,
  action text not null,
  resource_hash text not null,
  event_ref uuid,
  result text not null,
  reason text not null,
  policy_version text not null default 'financial-v1',
  changes jsonb not null default '{}'::jsonb
);
create index financial_audit_occurred_idx on private.financial_audit(occurred_at);
alter table private.financial_audit enable row level security;
revoke all on private.financial_audit from public,anon,authenticated,service_role;

create function private.append_financial_audit(p_action text,p_resource text,p_result text,
  p_reason text,p_changes jsonb default '{}'::jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
  insert into private.financial_audit(actor,action,resource_hash,event_ref,result,reason,changes)
  values(coalesce(nullif(current_setting('role',true),'none'),session_user),p_action,
    encode(extensions.digest(p_resource,'sha256'),'hex'),
    nullif(current_setting('albus.financial_event',true),'')::uuid,p_result,p_reason,p_changes)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function private.append_financial_audit(text,text,text,text,jsonb) from public,anon,authenticated,service_role;

create function private.reject_audit_rewrite() returns trigger
language plpgsql set search_path='' as $$
begin
  raise exception 'IMMUTABLE_FINANCIAL_AUDIT' using errcode='42501';
end $$;
revoke all on function private.reject_audit_rewrite() from public,anon,authenticated,service_role;
create trigger financial_audit_immutable before update or delete on private.financial_audit
  for each row execute function private.reject_audit_rewrite();
create trigger financial_audit_no_truncate before truncate on private.financial_audit
  for each statement execute function private.reject_audit_rewrite();

-- Every mutation is observed, including administrative/legacy paths. Copy only
-- allowlisted financial fields, never arbitrary payload or student content.
create function private.audit_financial_mutation() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_old jsonb; v_new jsonb; v_key text; v_reason text;
begin
  v_old := case when tg_op='INSERT' then '{}'::jsonb else to_jsonb(old) end;
  v_new := case when tg_op='DELETE' then '{}'::jsonb else to_jsonb(new) end;
  v_key := coalesce(v_new->>'user_id',v_old->>'user_id',v_new->>'event_id',v_old->>'event_id',
    v_new->>'original_transaction_id',v_old->>'original_transaction_id',v_new->>'key',v_old->>'key',
    v_new->>'product_id',v_old->>'product_id','unknown');
  v_reason := case when nullif(current_setting('albus.financial_event',true),'') is null
    then case when tg_table_name='entitlements' and tg_op='INSERT' and v_new->>'tier'='free'
      and v_new->>'expires_at' is null then 'baseline_free_entitlement' else 'outside_event_processor' end
    else 'verified_provider_event' end;
  perform private.append_financial_audit(tg_table_name||'.'||lower(tg_op),v_key,'committed',v_reason,
    jsonb_build_object('before',jsonb_strip_nulls(jsonb_build_object(
      'tier',v_old->'tier','expires_at',v_old->'expires_at','revoked_at',v_old->'revoked_at',
      'environment',v_old->'environment','net_microusd',v_old->'net_microusd','int_value',v_old->'int_value')),
      'after',jsonb_strip_nulls(jsonb_build_object(
      'tier',v_new->'tier','expires_at',v_new->'expires_at','revoked_at',v_new->'revoked_at',
      'environment',v_new->'environment','net_microusd',v_new->'net_microusd','int_value',v_new->'int_value'))));
  return coalesce(new,old);
end $$;
revoke all on function private.audit_financial_mutation() from public,anon,authenticated,service_role;
create trigger entitlement_financial_audit after insert or update or delete on public.entitlements
  for each row execute function private.audit_financial_mutation();
create trigger subscription_financial_audit after insert or update or delete on public.subscription_transactions
  for each row execute function private.audit_financial_mutation();
create trigger revenue_financial_audit after insert or update or delete on public.subscription_revenue
  for each row execute function private.audit_financial_mutation();
create trigger product_financial_audit after insert or update or delete on public.subscription_products
  for each row execute function private.audit_financial_mutation();
create trigger config_financial_audit after insert or update or delete on public.app_config
  for each row execute function private.audit_financial_mutation();

-- TRUNCATE is not a row mutation; deny it to workloads and observe owners.
revoke truncate on public.entitlements,public.subscription_transactions,public.subscription_revenue,
  public.subscription_products,public.app_config from public,anon,authenticated,service_role;
create function private.audit_financial_truncate() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  perform private.append_financial_audit(tg_table_name||'.truncate',tg_table_name,'committed','outside_event_processor');
  return null;
end $$;
revoke all on function private.audit_financial_truncate() from public,anon,authenticated,service_role;
create trigger entitlement_financial_truncate before truncate on public.entitlements
  for each statement execute function private.audit_financial_truncate();
create trigger subscription_financial_truncate before truncate on public.subscription_transactions
  for each statement execute function private.audit_financial_truncate();
create trigger revenue_financial_truncate before truncate on public.subscription_revenue
  for each statement execute function private.audit_financial_truncate();
create trigger product_financial_truncate before truncate on public.subscription_products
  for each statement execute function private.audit_financial_truncate();
create trigger config_financial_truncate before truncate on public.app_config
  for each statement execute function private.audit_financial_truncate();

create function public.enqueue_revenuecat_event(p_scope text,p_event_id text,p_payload jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_hash text; v_existing text;
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
  insert into private.financial_inbox(scope,event_id,payload,payload_hash)
    values(p_scope,p_event_id,p_payload,v_hash) on conflict(provider,scope,event_id) do nothing
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

create function public.process_financial_event(p_id uuid) returns text
language plpgsql security definer set search_path='' as $$
declare v private.financial_inbox%rowtype; s jsonb; r jsonb; t jsonb; v_result text;
  v_code text; v_previous text := current_setting('albus.financial_event',true);
begin
  select * into v from private.financial_inbox where id=p_id for update;
  if not found then raise exception 'FINANCIAL_EVENT_NOT_FOUND' using errcode='22023'; end if;
  if v.state='completed' then return v.result; end if;
  if v.state='dead' then return 'dead'; end if;
  if v.available_at>now() then return 'retry'; end if;
  update private.financial_inbox set attempts=attempts+1 where id=p_id;
  perform set_config('albus.financial_event',p_id::text,true);
  begin
    if v.payload->>'operation'='transfer' then
      t:=v.payload->'transfer';
      v_result:=public.transfer_verified_subscriptions(
        array(select jsonb_array_elements_text(t->'p_from')::uuid), (t->>'p_to')::uuid,
        t->>'p_event_id',(t->>'p_event_at')::timestamptz,
        array(select jsonb_array_elements_text(t->'p_allowed_app_ids')),
        t->>'p_app_id',t->>'p_store',t->>'p_environment');
    else
      s:=v.payload->'subscription';
      v_result:=public.apply_verified_subscription_state(
        s->>'p_original_transaction_id',(s->>'p_user_id')::uuid,s->>'p_latest_transaction_id',
        s->>'p_product_id',s->>'p_environment',(s->>'p_purchase_date')::timestamptz,
        (s->>'p_expires_at')::timestamptz,(s->>'p_revoked_at')::timestamptz,
        s->>'p_event_id',(s->>'p_event_at')::timestamptz,s->>'p_store',s->>'p_app_id');
      if v_result='unknown_product' then raise exception 'PRODUCT_NOT_MAPPED' using errcode='Q0020'; end if;
      r:=v.payload->'revenue';
      if r is not null then
        perform public.record_subscription_revenue(r->>'p_event_id',r->>'p_event_type',(r->>'p_user_id')::uuid,
          r->>'p_original_transaction_id',r->>'p_product_id',r->>'p_environment',
          (r->>'p_price_usd')::numeric,(r->>'p_tax_fraction')::numeric,
          (r->>'p_commission_fraction')::numeric,r->>'p_cancel_reason',(r->>'p_occurred_at')::timestamptz);
      end if;
    end if;
    if v_result is null then raise exception 'UNCLASSIFIED_FINANCIAL_RESULT'; end if;
    perform private.append_financial_audit('provider_event.processed',v.event_id,v_result,'verified_provider_event');
    update private.financial_inbox set state='completed',completed_at=now(),result=v_result,error_code=null where id=p_id;
  exception when others then
    -- Exception block rolls back ALL business effects and their audit rows.
    -- Persist only a machine code, never database error text or the payload.
    v_code:=sqlstate;
    update private.financial_inbox set state=case when attempts>=10 then 'dead' else 'retry' end,
      error_code=v_code,available_at=now()+make_interval(secs=>least(3600,30*(2^least(attempts,7))::integer))
      where id=p_id;
    perform private.append_financial_audit('provider_event.failed',v.event_id,'retry',v_code);
    v_result:='retry';
  end;
  perform set_config('albus.financial_event',coalesce(v_previous,''),true);
  return v_result;
end $$;
revoke all on function public.process_financial_event(uuid) from public,anon,authenticated;
grant execute on function public.process_financial_event(uuid) to service_role;

create function public.drain_financial_events(p_limit integer default 25) returns integer
language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_count integer:=0;
begin
  for v_id in select id from private.financial_inbox where state in ('pending','retry') and available_at<=now()
    order by received_at limit least(100,greatest(1,p_limit)) for update skip locked
  loop
    perform public.process_financial_event(v_id); v_count:=v_count+1;
  end loop;
  return v_count;
end $$;
revoke all on function public.drain_financial_events(integer) from public,anon,authenticated;
grant execute on function public.drain_financial_events(integer) to service_role;

create function public.requeue_financial_event(p_id uuid,p_ticket text) returns void
language plpgsql security definer set search_path='' as $$
begin
  if p_ticket is null or p_ticket !~ '^[A-Za-z0-9_/-]{3,100}$' then raise exception 'TICKET_REQUIRED'; end if;
  update private.financial_inbox set state='retry',attempts=0,available_at=now(),error_code=null
    where id=p_id and state='dead';
  if not found then raise exception 'NOT_DEAD_LETTER'; end if;
  perform private.append_financial_audit('provider_event.requeued',p_id::text,'queued',p_ticket);
end $$;
revoke all on function public.requeue_financial_event(uuid,text) from public,anon,authenticated,service_role;

-- After 30 days a completed event keeps only its identity, hash and result.
create function public.prune_financial_inbox() returns integer
language plpgsql security definer set search_path='' as $$
declare v_count integer;
begin
  -- Keep identity/hash/result tombstones for replay prevention, erase payload.
  update private.financial_inbox set payload='{}'::jsonb where state='completed'
    and completed_at<now()-interval '30 days' and payload<>'{}'::jsonb;
  get diagnostics v_count=row_count; return v_count;
end $$;
revoke all on function public.prune_financial_inbox() from public,anon,authenticated;
grant execute on function public.prune_financial_inbox() to service_role;

-- Existing pg_cron installation provides recovery without a webhook secret in SQL.
-- Named schedules update in place; cron runs only one instance per named job.
-- The webhook processes each event at once; this job only picks up retries, so
-- every five minutes is enough and keeps cron's run log small.
select cron.schedule('albus-financial-drain','*/5 * * * *',
  'select public.drain_financial_events(25)');
select cron.schedule('albus-financial-payload-retention','23 3 * * *',
  'select public.prune_financial_inbox()');
commit;
