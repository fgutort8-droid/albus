-- 20260911100000_weekly_ai_plan_allowance
--
-- Free students get a few AI step plans a week, then plan on the phone.
--
-- Until now an AI breakdown had no allowance of its own. How much planning a
-- student could do was expressed only as how many assignments they could hold
-- open, plus rate limits aimed at scripts. Every free student could therefore
-- ask for an AI plan on every assignment, and every one was a paid model call.
--
-- This gives breakdown the same shape grading already has: a weekly allowance
-- read from `plans`, with the house convention -- NULL is unlimited, 0 is not
-- included. Free gets 3. Plus and Pro stay NULL, so a paying student is limited
-- only by the rate limits and the per-account fair-use fuse, exactly as before.
--
-- Only completed calls count against the allowance (`ai_spend_count`), plus
-- reservations still in flight. A failed provider call does not spend one of a
-- student's three.

begin;

alter table public.plans
  add column breakdown_per_week integer check (breakdown_per_week >= 0);

comment on column public.plans.breakdown_per_week is
  'AI step plans per rolling 7 days. NULL = unlimited, 0 = not included.';

update public.plans set breakdown_per_week = 3    where tier = 'free';
update public.plans set breakdown_per_week = null where tier in ('plus', 'pro');

-- The gate, regenerated from the live definition with one branch changed:
-- breakdown now reads `breakdown_per_week` over a 7-day window where it used to
-- set no allowance at all. Everything else -- global fuses, risk bands, the
-- fair-use budget, rate limits, the reservation insert -- is byte-identical.
CREATE OR REPLACE FUNCTION public.check_and_record_ai_usage(p_user_id uuid, p_kind text, p_model text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_plan          public.plans%rowtype;
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
  v_hour_reserved bigint;
  v_day_reserved  bigint;
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
         coalesce(max(case when key = 'global_ai_calls_per_hour' then int_value end), 100),
         coalesce(max(case when key = 'ai_budget_per_hour_microusd' then int_value end), 2000000),
         coalesce(max(case when key = 'ai_budget_per_day_microusd' then int_value end), 10000000)
    into v_emergency, v_global_cap, v_hour_budget, v_day_budget
    from public.app_config;

  if v_emergency then
    raise exception 'AI_EMERGENCY_STOP' using errcode = 'Q0013';
  end if;

  select count(*), coalesce(sum(u.reserved_cost_microusd), 0)
    into v_global_used, v_hour_reserved
    from public.ai_usage u
   where u.created_at > now() - interval '1 hour';

  if v_global_used >= v_global_cap
     or v_hour_reserved + v_reservation > v_hour_budget then
    raise exception 'GLOBAL_CAPACITY_REACHED' using errcode = 'Q0004';
  end if;

  select coalesce(sum(u.reserved_cost_microusd), 0)
    into v_day_reserved
    from public.ai_usage u
   where u.created_at > now() - interval '1 day';

  if v_day_reserved + v_reservation > v_day_budget then
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

  select p.* into v_plan
    from public.plans p where p.tier = public.effective_tier(p_user_id);
  if not found then raise exception 'PLAN_UNKNOWN' using errcode = 'Q0005'; end if;

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
    (user_id, kind, model, attempt_state, reserved_cost_microusd)
  values
    (p_user_id, p_kind, v_model, 'reserved', v_reservation)
  returning id into v_id;
  return v_id;
end;
$function$;

revoke all on function public.check_and_record_ai_usage(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.check_and_record_ai_usage(uuid, text, text)
  to service_role;

-- my_plan() gains the breakdown meter and loses the chat one. Its return type
-- changes, which `create or replace` cannot do, so it is dropped and recreated.
-- Nothing depends on it, and the app never decoded the chat fields -- Ask Albus
-- was withdrawn in 20260909140000_remove_chat.
drop function public.my_plan();

create function public.my_plan()
returns table (
  tier                    text,
  display_name            text,
  price_cents             integer,
  currency                text,
  expires_at              timestamptz,

  active_tasks_limit      integer,
  active_tasks_used       integer,

  breakdown_limit_week    integer,
  breakdown_used_week     integer,
  breakdown_resets_at     timestamptz,

  grade_limit_week        integer,
  grade_used_week         integer,
  grade_resets_at         timestamptz,

  rubrics_limit           integer,
  rubrics_used            integer,

  tools_access            text,
  curriculum_intelligence boolean,
  advanced_models         boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_tier text;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;

  -- No argument, so it can only ever answer about the caller.
  v_tier := public.effective_tier(v_uid);

  return query
  select
    p.tier,
    p.display_name,
    p.price_cents,
    p.currency,
    (select e.expires_at from public.entitlements e where e.user_id = v_uid),

    p.active_tasks,
    (select count(*)::integer from public.assignments a
      where a.user_id = v_uid and a.status = 'active'),

    p.breakdown_per_week,
    public.ai_spend_count(v_uid, 'breakdown', interval '7 days'),
    public.ai_window_resets_at(v_uid, 'breakdown', interval '7 days'),

    p.grade_per_week,
    public.ai_spend_count(v_uid, 'grade', interval '7 days'),
    public.ai_window_resets_at(v_uid, 'grade', interval '7 days'),

    p.rubrics,
    (select count(*)::integer from public.rubrics r where r.user_id = v_uid),

    p.tools_access,
    p.curriculum_intelligence,
    p.advanced_models
  from public.plans p
  where p.tier = v_tier;
end;
$$;

comment on function public.my_plan() is
  'The caller''s plan, limits and current usage. NULL limit = unlimited, 0 = not included.';

revoke all on function public.my_plan() from public, anon;
grant execute on function public.my_plan() to authenticated;

do $$
begin
  if (select breakdown_per_week from public.plans where tier = 'free') is distinct from 3
     or exists (select 1 from public.plans
                 where tier in ('plus', 'pro') and breakdown_per_week is not null) then
    raise exception 'breakdown allowances are not free=3, plus/pro=unlimited';
  end if;
  if position('v_plan.breakdown_per_week' in
       pg_get_functiondef('public.check_and_record_ai_usage(uuid,text,text)'::regprocedure)) = 0 then
    raise exception 'the gate does not read breakdown_per_week';
  end if;
end $$;

commit;
