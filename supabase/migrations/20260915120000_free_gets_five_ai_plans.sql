-- 20260915120000_free_gets_five_ai_plans
--
-- Free gets five AI plans a week: one for each assignment it can hold open.
--
-- Every assignment a student adds asks for an AI plan. Free holds five open
-- assignments but had three AI plans a week, so a free student who filled
-- their list got phone plans for two of them. Five and five is the owner's
-- decision (15 Sep 2026).
--
-- It stays a weekly allowance rather than "one per open assignment". Finishing
-- or deleting an assignment frees its place, so a per-place rule would let a
-- student delete and re-add for as many paid AI calls as they liked.

begin;

update public.plans set breakdown_per_week = 5 where tier = 'free';

do $$
begin
  if (select breakdown_per_week from public.plans where tier = 'free') is distinct from 5 then
    raise exception 'Free does not have five AI plans a week';
  end if;
end $$;

commit;
