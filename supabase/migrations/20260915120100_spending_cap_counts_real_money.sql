-- 20260915120100_spending_cap_counts_real_money
--
-- The app-wide AI spending cap counts real money, and is US$1 a day.
--
-- The cap was US$2 an hour and US$10 a day, counted in reservations: the most
-- a call *could* cost, charged in full even after the call finished and
-- reported what it really cost. Reservations sit far above real prices. In
-- production an AI plan reserves 30,000 micro-USD and has averaged 2,600; a
-- marking reserves 450,000 and has averaged 76,000. So the figure on the cap
-- said nothing about the bill, and a cap low enough to protect the owner would
-- have refused ordinary use: at US$1 of reservations a day, two markings would
-- have used up the whole app.
--
-- The cap now uses the rule the per-account fair-use budget already uses
-- (`private.ai_account_cost`). A finished call counts what it cost. A call
-- still running, or one that ended without a measured cost, counts its worst
-- case, so a burst of calls cannot overshoot and a crashed call is never free.
--
-- US$1 a day follows the owner asking for far less than US$2 an hour
-- (15 Sep 2026). The most AI can then cost is about US$30 a month, and only if
-- the cap were reached every day; the busiest day in production so far cost
-- US$0.23. The hour carries the same figure because a lower one would refuse
-- markings: a marking must fit its 450,000 reservation under the cap while it
-- runs. Past the cap, free students get plans made on the phone and marking
-- asks to be tried again, so raise it as paying students arrive.

begin;

create or replace function private.ai_global_cost(p_since interval)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  -- `private.ai_account_cost`, across every account.
  select coalesce(sum(
    case
      when u.attempt_state = 'reserved' then u.reserved_cost_microusd
      when u.actual_cost_microusd is not null then u.actual_cost_microusd
      else u.reserved_cost_microusd
    end
  ), 0)::bigint
  from public.ai_usage u
  where u.created_at > now() - p_since;
$$;

revoke all on function private.ai_global_cost(interval)
  from public, anon, authenticated;

-- The gate, regenerated from 20260911100000_weekly_ai_plan_allowance with the
-- global money checks changed: they read `private.ai_global_cost` where they
-- summed reservations, and a missing setting falls back to US$1 rather than
-- the old US$2 and US$10. Everything else is identical.
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
         coalesce(max(case when key = 'global_ai_calls_per_hour' then int_value end), 100),
         coalesce(max(case when key = 'ai_budget_per_hour_microusd' then int_value end), 1000000),
         coalesce(max(case when key = 'ai_budget_per_day_microusd' then int_value end), 1000000)
    into v_emergency, v_global_cap, v_hour_budget, v_day_budget
    from public.app_config;

  if v_emergency then
    raise exception 'AI_EMERGENCY_STOP' using errcode = 'Q0013';
  end if;

  select count(*) into v_global_used
    from public.ai_usage u
   where u.created_at > now() - interval '1 hour';
  v_hour_spend := private.ai_global_cost(interval '1 hour');

  if v_global_used >= v_global_cap
     or v_hour_spend + v_reservation > v_hour_budget then
    raise exception 'GLOBAL_CAPACITY_REACHED' using errcode = 'Q0004';
  end if;

  v_day_spend := private.ai_global_cost(interval '1 day');

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

insert into public.app_config (key, int_value) values
  ('ai_budget_per_hour_microusd', 1000000), -- US$1 of real spending / hour
  ('ai_budget_per_day_microusd',  1000000)  -- US$1 of real spending / day
on conflict (key) do update set int_value = excluded.int_value, updated_at = now();

do $$
declare
  v_gate text := pg_get_functiondef(
    'public.check_and_record_ai_usage(uuid,text,text)'::regprocedure);
begin
  if position('private.ai_global_cost(interval ''1 hour'')' in v_gate) = 0
     or position('private.ai_global_cost(interval ''1 day'')' in v_gate) = 0
     or position('sum(u.reserved_cost_microusd)' in v_gate) > 0 then
    raise exception 'the gate does not cap real spending';
  end if;
  if exists (select 1 from public.app_config
              where key in ('ai_budget_per_hour_microusd', 'ai_budget_per_day_microusd')
                and int_value is distinct from 1000000) then
    raise exception 'the AI spending cap is not US$1';
  end if;
end $$;

commit;
