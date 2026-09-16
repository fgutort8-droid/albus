-- Every limit on every tier, asserted against the server that enforces it.
--
-- Each refusal is checked by its exact error code, never merely "it threw":
-- a test that accepts any error passes when the wrong limit fires, and the
-- whole point of this file is that the right one does.
--
-- Prior usage is seeded two days back. That sits inside the 7-day allowance
-- window and outside the hourly and daily rate-limit windows, so what these
-- assertions measure is the plan -- not a rate limit that happens to coincide.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;
select no_plan();

-- The global spend fuses are a safety net, not an entitlement. Lifted inside
-- this transaction (which always rolls back) so that a refusal below can only
-- ever be the plan speaking.
update public.app_config set int_value = 1000000000
 where key in ('ai_budget_per_hour_microusd', 'ai_budget_per_day_microusd');
update public.app_config set int_value = 100000 where key = 'global_ai_calls_per_hour';

create function pg_temp.student(p_id uuid) returns void language sql as $$
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
  ) values (
    p_id, '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', null, '', '{}', '{}', now(), now(), true
  );
$$;

-- N earlier calls of one kind, in one outcome, some time ago.
create function pg_temp.used(
  p_uid uuid, p_kind text, p_n integer,
  p_ago interval default interval '2 days', p_state text default 'completed'
) returns void language sql as $$
  insert into public.ai_usage (user_id, kind, model, attempt_state,
                               reserved_cost_microusd, created_at)
  select p_uid, p_kind, 'claude-haiku-4-5', p_state, 1, now() - p_ago
    from generate_series(1, p_n);
$$;

create function pg_temp.clear(p_uid uuid) returns void language sql as $$
  delete from public.ai_usage where user_id = p_uid;
$$;

create function pg_temp.tasks(p_uid uuid, p_n integer) returns void language sql as $$
  insert into public.assignments (user_id, title, deadline, estimated_minutes)
  select p_uid, 'Task ' || g, now() + interval '7 days', 60
    from generate_series(1, p_n) g;
$$;

create function pg_temp.rubrics(p_uid uuid, p_n integer) returns void language sql as $$
  insert into public.rubrics (user_id, name)
  select p_uid, 'Rubric ' || g from generate_series(1, p_n) g;
$$;

select pg_temp.student('a1000000-0000-4000-8000-000000000001');   -- Free
select pg_temp.student('a1000000-0000-4000-8000-000000000002');   -- Plus
select pg_temp.student('a1000000-0000-4000-8000-000000000003');   -- Pro
select pg_temp.student('a1000000-0000-4000-8000-000000000004');   -- Plus, lapsed

insert into public.entitlements (user_id, tier, expires_at) values
  ('a1000000-0000-4000-8000-000000000002', 'plus', now() + interval '1 month'),
  ('a1000000-0000-4000-8000-000000000003', 'pro',  now() + interval '1 month'),
  ('a1000000-0000-4000-8000-000000000004', 'plus', now() - interval '1 day');

select is(public.effective_tier('a1000000-0000-4000-8000-000000000004'), 'free',
          'a subscription that has lapsed is Free again');

-- -------------------------------------------------------------------------
-- The table itself. Pricing is decided by a person; a migration that changes
-- it by accident must fail here rather than reach a student.

select results_eq(
  $$select tier, active_tasks, breakdown_per_week, grade_per_week, rubrics
      from public.plans order by rank$$,
  $$values ('free', 5,          5,             0, 3),
           ('plus', 10,         null::integer, 2, 5),
           ('pro',  null::integer, null::integer, 5, null::integer)$$,
  'every tier carries exactly the approved limits');

-- The fair-use ceiling exists to bound "unlimited" AI plans, not to describe
-- a student's real month -- pinned here so nobody loosens it back toward the
-- rate limit's theoretical maximum (money the app-wide cap would then also
-- have to catch) by accident.
select results_eq(
  $$select tier, rolling_30d_cost_microusd from private.ai_tier_budgets order by tier$$,
  $$values ('free', 1000000), ('plus', 3000000), ('pro', 6000000)$$,
  'fair-use ceilings sit near real use, not the rate limit''s theoretical maximum');

-- -------------------------------------------------------------------------
-- AI step plans.

select pg_temp.used('a1000000-0000-4000-8000-000000000001', 'breakdown', 4);
select lives_ok(
  $$select public.check_and_record_ai_usage(
      'a1000000-0000-4000-8000-000000000001', 'breakdown', 'claude-haiku-4-5')$$,
  'Free: the fifth AI plan of the week is allowed');
select throws_ok(
  $$select public.check_and_record_ai_usage(
      'a1000000-0000-4000-8000-000000000001', 'breakdown', 'claude-haiku-4-5')$$,
  'Q0006', 'ALLOWANCE_WEEKLY',
  'Free: the sixth AI plan of the week is refused as a used-up allowance');

select pg_temp.clear('a1000000-0000-4000-8000-000000000001');
select pg_temp.used('a1000000-0000-4000-8000-000000000001', 'breakdown', 5, interval '8 days');
select lives_ok(
  $$select public.check_and_record_ai_usage(
      'a1000000-0000-4000-8000-000000000001', 'breakdown', 'claude-haiku-4-5')$$,
  'Free: plans from more than a week ago no longer count');

select pg_temp.clear('a1000000-0000-4000-8000-000000000001');
select pg_temp.used('a1000000-0000-4000-8000-000000000001', 'breakdown', 5,
                    interval '2 days', 'failed');
select lives_ok(
  $$select public.check_and_record_ai_usage(
      'a1000000-0000-4000-8000-000000000001', 'breakdown', 'claude-haiku-4-5')$$,
  'Free: a plan that failed to generate does not spend one of the five');

select pg_temp.used('a1000000-0000-4000-8000-000000000002', 'breakdown', 30);
select lives_ok(
  $$select public.check_and_record_ai_usage(
      'a1000000-0000-4000-8000-000000000002', 'breakdown', 'claude-haiku-4-5')$$,
  'Plus: AI plans are unlimited');

select pg_temp.used('a1000000-0000-4000-8000-000000000003', 'breakdown', 30);
select lives_ok(
  $$select public.check_and_record_ai_usage(
      'a1000000-0000-4000-8000-000000000003', 'breakdown', 'claude-haiku-4-5')$$,
  'Pro: AI plans are unlimited');

select pg_temp.used('a1000000-0000-4000-8000-000000000004', 'breakdown', 5);
select throws_ok(
  $$select public.check_and_record_ai_usage(
      'a1000000-0000-4000-8000-000000000004', 'breakdown', 'claude-haiku-4-5')$$,
  'Q0006', 'ALLOWANCE_WEEKLY',
  'Lapsed Plus: back to five AI plans a week');

-- -------------------------------------------------------------------------
-- AI marking.

select throws_ok(
  $$select public.check_and_record_ai_usage(
      'a1000000-0000-4000-8000-000000000001', 'grade', 'claude-opus-5')$$,
  'Q0007', 'PLAN_UPGRADE_REQUIRED',
  'Free: marking is not included -- an upgrade, not a used-up allowance');

select pg_temp.used('a1000000-0000-4000-8000-000000000002', 'grade', 1);
select lives_ok(
  $$select public.check_and_record_ai_usage(
      'a1000000-0000-4000-8000-000000000002', 'grade', 'claude-opus-5')$$,
  'Plus: the second marking of the week is allowed');
select throws_ok(
  $$select public.check_and_record_ai_usage(
      'a1000000-0000-4000-8000-000000000002', 'grade', 'claude-opus-5')$$,
  'Q0006', 'ALLOWANCE_WEEKLY',
  'Plus: the third marking of the week is refused');

select pg_temp.used('a1000000-0000-4000-8000-000000000003', 'grade', 4);
select lives_ok(
  $$select public.check_and_record_ai_usage(
      'a1000000-0000-4000-8000-000000000003', 'grade', 'claude-opus-5')$$,
  'Pro: the fifth marking of the week is allowed');
select throws_ok(
  $$select public.check_and_record_ai_usage(
      'a1000000-0000-4000-8000-000000000003', 'grade', 'claude-opus-5')$$,
  'Q0006', 'ALLOWANCE_WEEKLY',
  'Pro: the sixth marking of the week is refused');

select throws_ok(
  $$select public.check_and_record_ai_usage(
      'a1000000-0000-4000-8000-000000000004', 'grade', 'claude-opus-5')$$,
  'Q0007', 'PLAN_UPGRADE_REQUIRED',
  'Lapsed Plus: marking stops when the subscription does');

-- -------------------------------------------------------------------------
-- Open assignments.

select lives_ok($$select pg_temp.tasks('a1000000-0000-4000-8000-000000000001', 5)$$,
                'Free: five open assignments');
select throws_ok($$select pg_temp.tasks('a1000000-0000-4000-8000-000000000001', 1)$$,
                 'Q0001', 'PLAN_TASK_LIMIT_REACHED',
                 'Free: a sixth open assignment is refused');
update public.assignments set status = 'completed'
 where id = (select id from public.assignments
              where user_id = 'a1000000-0000-4000-8000-000000000001' limit 1);
select lives_ok($$select pg_temp.tasks('a1000000-0000-4000-8000-000000000001', 1)$$,
                'Free: finishing an assignment frees its place');

select lives_ok($$select pg_temp.tasks('a1000000-0000-4000-8000-000000000002', 10)$$,
                'Plus: ten open assignments');
select throws_ok($$select pg_temp.tasks('a1000000-0000-4000-8000-000000000002', 1)$$,
                 'Q0001', 'PLAN_TASK_LIMIT_REACHED',
                 'Plus: an eleventh open assignment is refused');

select lives_ok($$select pg_temp.tasks('a1000000-0000-4000-8000-000000000003', 11)$$,
                'Pro: open assignments are unlimited');

-- -------------------------------------------------------------------------
-- Saved rubrics.

select lives_ok($$select pg_temp.rubrics('a1000000-0000-4000-8000-000000000001', 3)$$,
                'Free: three saved rubrics');
select throws_ok($$select pg_temp.rubrics('a1000000-0000-4000-8000-000000000001', 1)$$,
                 'Q0011', 'RUBRIC_PLAN_LIMIT',
                 'Free: a fourth saved rubric is refused');

select lives_ok($$select pg_temp.rubrics('a1000000-0000-4000-8000-000000000002', 5)$$,
                'Plus: five saved rubrics');
select throws_ok($$select pg_temp.rubrics('a1000000-0000-4000-8000-000000000002', 1)$$,
                 'Q0011', 'RUBRIC_PLAN_LIMIT',
                 'Plus: a sixth saved rubric is refused');

select lives_ok($$select pg_temp.rubrics('a1000000-0000-4000-8000-000000000003', 6)$$,
                'Pro: saved rubrics are unlimited');

-- -------------------------------------------------------------------------
-- What the student is shown. The meter and the gate must read the same
-- numbers, or a student is told they have a plan left that the server refuses.

select pg_temp.clear('a1000000-0000-4000-8000-000000000001');
select pg_temp.used('a1000000-0000-4000-8000-000000000001', 'breakdown', 2);

set local role authenticated;
select set_config('request.jwt.claim.sub', 'a1000000-0000-4000-8000-000000000001', true);
select results_eq(
  $$select breakdown_limit_week, breakdown_used_week from public.my_plan()$$,
  $$values (5, 2)$$,
  'Free: the meter shows 2 of 5 AI plans used');

select set_config('request.jwt.claim.sub', 'a1000000-0000-4000-8000-000000000002', true);
select is((select breakdown_limit_week from public.my_plan()), null::integer,
          'Plus: the meter shows AI plans as unlimited');
reset role;

select * from finish();
rollback;
