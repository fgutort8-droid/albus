-- 20260916090000_tighten_fair_use_ceilings
--
-- The per-account fair-use ceiling protects "unlimited AI plans" from being
-- literally unlimited spend, but its number came from the rate limit's
-- theoretical maximum, not from what a student actually costs.
--
-- Pro's only truly unlimited feature is the AI plan -- breakdown carries no
-- weekly allowance on Plus or Pro, only an hourly/daily rate limit meant to
-- stop bursts. Run that rate limit flat out on Pro -- 150 requests a day,
-- every day, for a month, which is no human tapping a button -- and it alone
-- costs about US$28 at the highest price a plan has ever billed. Add five
-- markings a week at the highest price a marking has ever billed and the
-- theoretical month tops US$30. The old US$12 ceiling was already doing real
-- work stopping that -- it is well below US$30 -- but it was set five to ten
-- times above what a real student costs, leaving room only a compromised
-- account or a script could use, never a student using the app:
--
--   heaviest realistic month, at the highest prices ever billed  Plus  Pro
--     AI plans (40 or 60 of them, generous for a human)          $0.25 $0.38
--     AI markings (the plan's full weekly allowance)             $0.94 $2.34
--     total                                                      $1.19 $2.72
--
-- New ceilings sit at roughly twice that heaviest realistic month: Pro
-- US$6, Plus US$3. Free is untouched -- it costs cents, and its number was
-- never about margin.
--
-- Hitting this ceiling is not a broken-app moment for planning: `breakdown`
-- is one of the kinds the client already treats as "plan on the phone
-- instead" (`PlanService.Failure.plansLocally`), so a Pro student who somehow
-- ran up six real dollars of AI cost in one month gets a phone-made study
-- plan, not an error.

begin;

update private.ai_tier_budgets set rolling_30d_cost_microusd = 3000000 where tier = 'plus';
update private.ai_tier_budgets set rolling_30d_cost_microusd = 6000000 where tier = 'pro';

do $$
begin
  if (select rolling_30d_cost_microusd from private.ai_tier_budgets where tier = 'free') is distinct from 1000000
     or (select rolling_30d_cost_microusd from private.ai_tier_budgets where tier = 'plus') is distinct from 3000000
     or (select rolling_30d_cost_microusd from private.ai_tier_budgets where tier = 'pro') is distinct from 6000000 then
    raise exception 'fair-use ceilings are not US$1 / US$3 / US$6';
  end if;
end $$;

commit;
