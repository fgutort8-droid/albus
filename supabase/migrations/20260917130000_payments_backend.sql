-- 20260917130000_payments_backend
--
-- What the first real purchase needs. Decided with Felipe on 17 Sep 2026.
--
-- 1. THE PRODUCTS. `subscription_products` was empty, so a verified purchase
--    answered `unknown_product` and granted nothing while Apple kept the money.
--    The four App Store products are mapped here under the ids App Store
--    Connect and RevenueCat use.
--
-- 2. APPLE'S TEST PURCHASES UNLOCK THE PLAN. App Review buys with sandbox
--    accounts against the production backend, and so does every TestFlight
--    tester. With sandbox ignored the reviewer pays, nothing unlocks, and the
--    build is rejected. Sandbox subscriptions run on Apple's accelerated clock
--    and stop renewing on their own, each account keeps its monthly AI
--    ceiling, and sandbox money never raises the paid fuse (item 5), so what a
--    tester can cost is small and short-lived.
--
-- 3. RESTORES MOVE THE PLAN. Accounts start anonymous, so a reinstall or a new
--    phone is a new account. When the student taps Restore, RevenueCat moves
--    the purchase and sends TRANSFER. There was no handler, and the next
--    renewal naming the new account was refused as a `conflict`: the student
--    paid and stayed Free. `transfer_subscriptions` moves the transactions and
--    recomputes both accounts, and a renewal that arrives before its transfer
--    is now kept for the current owner instead of being dropped.
--    The last 30 days of AI use move too. Every per-account limit -- the
--    weekly markings, the rate limits, the monthly ceiling -- counts that
--    history, so one subscription restored into fresh account after fresh
--    account starts each one used, not new. This is what makes RevenueCat's
--    default "Transfer to new App User ID" safe here; the alternative, "only
--    if there are no active subscriptions", would refuse exactly the restore
--    a student with a new phone needs.
--
-- 4. TWO FUSES INSTEAD OF ONE. The US$1-a-day cap was shared, so accounts that
--    cost nothing to create could use it up and pause marking for everyone who
--    pays. Each call now belongs to the pool of the plan that made it: free
--    accounts share one fuse, paying accounts another, and the call-count fuse
--    is split the same way. Free keeps US$1 a day.
--
-- 5. THE PAID FUSE GROWS WITH INCOME. Felipe's rule: AI may use at most 25% of
--    what subscribers paid. Each purchase event records its proceeds -- the
--    price less RevenueCat's tax and commission estimates, both fractions of
--    the gross -- and refunds count against. The paid day budget is 25% of
--    the last 30 days of production proceeds, divided by 30, never below the
--    US$1 floor a marking needs to fit its 450,000 reservation. The hour
--    budget is a quarter of that, never below the same floor.

begin;

-- ------------------------------------------------------------ 1. products

insert into public.subscription_products (product_id, tier) values
  ('com.felipegutierrez.albus.plus.monthly', 'plus'),
  ('com.felipegutierrez.albus.plus.annual',  'plus'),
  ('com.felipegutierrez.albus.pro.monthly',  'pro'),
  ('com.felipegutierrez.albus.pro.annual',   'pro')
on conflict (product_id) do update set tier = excluded.tier, active = true;

-- ---------------------------------------------------------- 2. and 5. rules

insert into public.app_config (key, int_value) values
  ('allow_sandbox_subscriptions', 1),     -- App Review and TestFlight buy in sandbox
  ('ai_budget_revenue_share_bps', 2500)   -- the paid fuse: 25% of proceeds
on conflict (key) do update set int_value = excluded.int_value, updated_at = now();

-- ------------------------------------------------ entitlement, in one place

-- What an account is entitled to: every verified, unexpired, unrevoked
-- transaction it owns, highest plan first. Called whenever ownership or state
-- changes, always under that account's owner lock.
create or replace function private.recompute_entitlement(p_user_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_allow_sandbox boolean;
  v_tier          text;
  v_expires       timestamptz;
  v_transaction   text;
begin
  if p_user_id is null
     or not exists (select 1 from auth.users u where u.id = p_user_id) then
    return 'invalid';
  end if;

  select coalesce(max(c.int_value), 0) = 1 into v_allow_sandbox
    from public.app_config c
   where c.key = 'allow_sandbox_subscriptions';

  -- Choosing by plan rank preserves Pro when an old Plus expiration arrives
  -- after an upgrade; choosing by expiry within one rank preserves the longest
  -- paid period.
  select sp.tier, s.expires_at, s.original_transaction_id
    into v_tier, v_expires, v_transaction
    from public.subscription_transactions s
    join public.subscription_products sp on sp.product_id = s.product_id
    join public.plans p on p.tier = sp.tier
   where s.user_id = p_user_id
     and (s.environment = 'Production'
          or (v_allow_sandbox and s.environment = 'Sandbox'))
     and s.revoked_at is null
     and s.expires_at is not null
     and s.expires_at > now()
   order by p.rank desc, s.expires_at desc, s.original_transaction_id
   limit 1;

  insert into public.entitlements
    (user_id, tier, expires_at, original_transaction_id, updated_at)
  values (p_user_id, coalesce(v_tier, 'free'), v_expires, v_transaction, now())
  on conflict (user_id) do update set
    tier = excluded.tier,
    expires_at = excluded.expires_at,
    original_transaction_id = excluded.original_transaction_id,
    updated_at = now();

  return case when v_tier is not null then 'active_' || v_tier else 'inactive' end;
end;
$$;

revoke all on function private.recompute_entitlement(uuid)
  from public, anon, authenticated;

-- Regenerated from 20260830114547_close_direct_write_and_request_abuse. Two
-- changes: a conflicting event's facts are kept for the current owner (item
-- 3), and entitlement comes from `private.recompute_entitlement`, which counts
-- sandbox transactions when they are allowed (item 2).
CREATE OR REPLACE FUNCTION public.apply_subscription_state(p_original_transaction_id text, p_user_id uuid, p_latest_transaction_id text, p_product_id text, p_environment text, p_purchase_date timestamp with time zone, p_expires_at timestamp with time zone, p_revoked_at timestamp with time zone, p_event_id text, p_event_at timestamp with time zone)
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

  perform pg_advisory_xact_lock(
    hashtextextended('albus:subscription:' || p_original_transaction_id, 0));

  select * into v_existing
    from public.subscription_transactions s
   where s.original_transaction_id = p_original_transaction_id;
  v_had_existing := found;

  if v_had_existing and v_existing.last_event_at is not null
     and (p_event_at < v_existing.last_event_at
          or p_event_id = v_existing.last_event_id) then
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

  if v_owner is null then return 'unlinked'; end if;

  v_result := private.recompute_entitlement(v_owner);
  return case when v_conflict then 'conflict' else v_result end;
end;
$function$;

-- ------------------------------------------------------------ 3. transfers

-- One delivery, one effect, for webhook events that are not tied to a single
-- transaction row. RevenueCat retries reuse the event id.
create table if not exists public.subscription_webhook_events (
  event_id     text primary key check (length(event_id) between 1 and 255),
  event_type   text not null check (length(event_type) between 1 and 64),
  processed_at timestamptz not null default now()
);

alter table public.subscription_webhook_events enable row level security;
revoke all on public.subscription_webhook_events from public, anon, authenticated;

create or replace function public.transfer_subscriptions(
  p_from uuid[],
  p_to uuid,
  p_event_id text,
  p_event_at timestamptz
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_transaction text;
  v_user        uuid;
  v_previous    uuid[];
  v_moved       integer;
begin
  if p_to is null
     or p_event_id is null or length(p_event_id) > 255
     or p_event_at is null
     or not exists (select 1 from auth.users u where u.id = p_to) then
    return 'invalid';
  end if;

  insert into public.subscription_webhook_events (event_id, event_type)
  values (p_event_id, 'TRANSFER')
  on conflict (event_id) do nothing;
  if not found then return 'stale'; end if;

  -- apply_subscription_state's lock order: transactions first, then accounts,
  -- each in a fixed order. A renewal for one of these transactions either
  -- finishes before the move or starts after it and reads the new owner.
  for v_transaction in
    select s.original_transaction_id
      from public.subscription_transactions s
     where s.user_id = any(coalesce(p_from, '{}'::uuid[]))
     order by 1
  loop
    perform pg_advisory_xact_lock(
      hashtextextended('albus:subscription:' || v_transaction, 0));
  end loop;

  for v_user in
    select distinct t.u
      from unnest(array_append(coalesce(p_from, '{}'::uuid[]), p_to)) as t(u)
     where t.u is not null
     order by 1
  loop
    perform pg_advisory_xact_lock(
      hashtextextended('albus:subscription-owner:' || v_user::text, 0));
  end loop;

  select coalesce(array_agg(distinct s.user_id), '{}'::uuid[]) into v_previous
    from public.subscription_transactions s
   where s.user_id = any(coalesce(p_from, '{}'::uuid[]))
     and s.user_id <> p_to;

  update public.subscription_transactions s
     set user_id = p_to,
         updated_at = now()
   where s.user_id = any(v_previous);
  get diagnostics v_moved = row_count;

  -- The usage follows the plan, or every restore would hand out a fresh set
  -- of limits. 30 days is the longest window any per-account limit reads.
  -- The AI gate's own lock order, global then accounts, so a call already
  -- being checked finishes on the old account and is moved with the rest.
  if v_moved > 0 then
    perform pg_advisory_xact_lock(hashtextextended('albus:ai_usage:global', 0));
    for v_user in
      select distinct t.u
        from unnest(array_append(v_previous, p_to)) as t(u)
       order by 1
    loop
      perform pg_advisory_xact_lock(
        hashtextextended('albus:ai_usage:' || v_user::text, 0));
    end loop;

    update public.ai_usage u
       set user_id = p_to
     where u.user_id = any(v_previous)
       and u.created_at > now() - interval '30 days';
  end if;

  -- Both sides: the old account loses the plan, the new one gains it.
  for v_user in
    select distinct t.u
      from unnest(array_append(coalesce(p_from, '{}'::uuid[]), p_to)) as t(u)
     where t.u is not null
  loop
    perform private.recompute_entitlement(v_user);
  end loop;

  return case when v_moved > 0 then 'transferred' else 'nothing_to_transfer' end;
end;
$$;

revoke all on function public.transfer_subscriptions(uuid[], uuid, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.transfer_subscriptions(uuid[], uuid, text, timestamptz)
  to service_role;

-- ------------------------------------------------------ 5. what came in

create table if not exists public.subscription_revenue (
  event_id                text primary key check (length(event_id) between 1 and 255),
  event_type              text not null check (length(event_type) between 1 and 64),
  user_id                 uuid references auth.users (id) on delete set null,
  original_transaction_id text check (length(original_transaction_id) <= 255),
  product_id              text check (length(product_id) <= 255),
  environment             text not null check (environment in ('Sandbox', 'Production')),
  net_microusd            bigint not null,
  occurred_at             timestamptz not null,
  created_at              timestamptz not null default now()
);

comment on table public.subscription_revenue is
  'Proceeds per RevenueCat event, in micro-USD after estimated tax and store commission. Refunds are negative. Only production rows feed the paid AI fuse.';

create index if not exists subscription_revenue_production_idx
  on public.subscription_revenue (occurred_at)
  where environment = 'Production';

alter table public.subscription_revenue enable row level security;
revoke all on public.subscription_revenue from public, anon, authenticated;

create or replace function public.record_subscription_revenue(
  p_event_id text,
  p_event_type text,
  p_user_id uuid,
  p_original_transaction_id text,
  p_product_id text,
  p_environment text,
  p_price_usd numeric,
  p_tax_fraction numeric,
  p_commission_fraction numeric,
  p_cancel_reason text,
  p_occurred_at timestamptz
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sign  integer;
  v_gross numeric;
  v_keep  numeric;
  v_user  uuid;
begin
  if p_event_id is null or length(p_event_id) > 255
     or p_event_type is null or length(p_event_type) > 64
     or p_occurred_at is null
     or p_environment not in ('Production', 'Sandbox') then
    return 'invalid';
  end if;

  -- Money in: a purchase, a renewal, a reversed refund. Money out: a refund,
  -- which RevenueCat reports as a CANCELLATION for customer support. The sign
  -- comes from the event rather than the price, so it holds however the price
  -- itself is signed.
  v_sign := case
    when p_event_type in ('INITIAL_PURCHASE', 'RENEWAL',
                          'NON_RENEWING_PURCHASE', 'REFUND_REVERSED') then 1
    when p_event_type = 'CANCELLATION' and p_cancel_reason = 'CUSTOMER_SUPPORT' then -1
    else 0
  end;
  -- No Albus product costs anywhere near US$1,000; a larger figure is an
  -- error, and trusting it would open the fuse.
  v_gross := least(abs(coalesce(p_price_usd, 0)), 1000);
  if v_sign = 0 or v_gross = 0 then
    return 'no_revenue';
  end if;

  -- RevenueCat's estimates are fractions of the gross. A missing one assumes
  -- a high rate rather than none, so an incomplete event can only understate
  -- income, and understated income only keeps the fuse lower.
  v_keep := greatest(0, 1
    - least(1, greatest(0, coalesce(p_tax_fraction, 0.25)))
    - least(1, greatest(0, coalesce(p_commission_fraction, 0.30))));

  -- An account that no longer exists is kept as NULL; the money still moved.
  select u.id into v_user from auth.users u where u.id = p_user_id;

  insert into public.subscription_revenue (
    event_id, event_type, user_id, original_transaction_id, product_id,
    environment, net_microusd, occurred_at
  ) values (
    p_event_id, p_event_type, v_user,
    left(p_original_transaction_id, 255), left(p_product_id, 255),
    p_environment, v_sign * round(v_gross * v_keep * 1000000)::bigint, p_occurred_at
  )
  on conflict (event_id) do nothing;

  if not found then return 'stale'; end if;
  return 'recorded';
end;
$$;

revoke all on function public.record_subscription_revenue(
  text, text, uuid, text, text, text, numeric, numeric, numeric, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.record_subscription_revenue(
  text, text, uuid, text, text, text, numeric, numeric, numeric, text, timestamptz)
  to service_role;

-- ------------------------------------------------------------- 4. pools

-- Existing rows predate the split. Counting them as free is the conservative
-- choice: the free fuse is the one that never grows.
alter table public.ai_usage
  add column if not exists budget_pool text not null default 'free'
    check (budget_pool in ('free', 'paid'));

comment on column public.ai_usage.budget_pool is
  'Which app-wide fuse this call spends from, chosen from the caller''s plan when it was reserved.';

create index if not exists ai_usage_pool_created_idx
  on public.ai_usage (budget_pool, created_at);

-- `private.ai_global_cost`, for one pool.
create or replace function private.ai_pool_cost(p_pool text, p_since interval)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(
    case
      when u.attempt_state = 'reserved' then u.reserved_cost_microusd
      when u.actual_cost_microusd is not null then u.actual_cost_microusd
      else u.reserved_cost_microusd
    end
  ), 0)::bigint
  from public.ai_usage u
  where u.created_at > now() - p_since
    and u.budget_pool = p_pool;
$$;

revoke all on function private.ai_pool_cost(text, interval)
  from public, anon, authenticated;

create or replace function private.ai_pool_budget(p_pool text)
returns table (hour_budget bigint, day_budget bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_hour_floor bigint;
  v_day_floor  bigint;
  v_share_bps  bigint;
  v_proceeds   bigint;
  v_day        bigint;
begin
  select coalesce(max(case when c.key = 'ai_budget_per_hour_microusd' then c.int_value end), 1000000),
         coalesce(max(case when c.key = 'ai_budget_per_day_microusd'  then c.int_value end), 1000000),
         coalesce(max(case when c.key = 'ai_budget_revenue_share_bps' then c.int_value end), 0)
    into v_hour_floor, v_day_floor, v_share_bps
    from public.app_config c;

  if p_pool is distinct from 'paid' then
    return query select v_hour_floor, v_day_floor;
    return;
  end if;

  -- Real money only. Sandbox purchases are free to make.
  select greatest(0, coalesce(sum(r.net_microusd), 0))::bigint into v_proceeds
    from public.subscription_revenue r
   where r.environment = 'Production'
     and r.occurred_at > now() - interval '30 days';

  v_day := greatest(
    v_day_floor,
    v_proceeds * least(greatest(v_share_bps, 0), 10000) / 10000 / 30);

  return query select greatest(v_hour_floor, v_day / 4), v_day;
end;
$$;

revoke all on function private.ai_pool_budget(text)
  from public, anon, authenticated;

-- The gate, regenerated from 20260915120100_spending_cap_counts_real_money.
-- Changed: the plan is read before the fuses, because it chooses the pool;
-- the call count, the hour and the day are all measured within that pool;
-- the reservation records its pool. Everything else is identical.
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
  if p_user_id is null
     or not exists (select 1 from auth.users u where u.id = p_user_id) then
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

-- --------------------------------------------------------------- verify

do $$
declare
  v_gate text := pg_get_functiondef(
    'public.check_and_record_ai_usage(uuid,text,text)'::regprocedure);
begin
  if (select count(*) from public.subscription_products
       where product_id like 'com.felipegutierrez.albus.%' and active) <> 4 then
    raise exception 'the four App Store products are not all mapped';
  end if;
  if (select c.int_value from public.app_config c
       where c.key = 'allow_sandbox_subscriptions') is distinct from 1 then
    raise exception 'App Review purchases would still unlock nothing';
  end if;
  if (select c.int_value from public.app_config c
       where c.key = 'ai_budget_revenue_share_bps') is distinct from 2500 then
    raise exception 'the paid fuse is not 25%% of proceeds';
  end if;
  if position('private.ai_pool_cost(v_pool, interval ''1 hour'')' in v_gate) = 0
     or position('private.ai_pool_cost(v_pool, interval ''1 day'')' in v_gate) = 0
     or position('private.ai_global_cost' in v_gate) > 0
     or position('u.budget_pool = v_pool' in v_gate) = 0 then
    raise exception 'the gate does not spend from separate pools';
  end if;
  if to_regprocedure('public.transfer_subscriptions(uuid[],uuid,text,timestamptz)') is null
     or has_function_privilege('authenticated',
          'public.transfer_subscriptions(uuid[],uuid,text,timestamptz)', 'EXECUTE')
     or has_function_privilege('authenticated',
          'public.record_subscription_revenue(text,text,uuid,text,text,text,numeric,numeric,numeric,text,timestamptz)',
          'EXECUTE') then
    raise exception 'a subscription RPC is missing or callable by students';
  end if;
end $$;

commit;
