-- The app-wide AI spending cap, asserted in money.
--
-- The cap is the owner's loss ceiling: the most AI may cost in an hour or a
-- day, whoever is asking. Finished calls count what they really cost; calls
-- still running count their worst case. When finished calls counted their
-- worst case too, a US$1 cap would have shut the app after two markings.
--
-- Earlier calls belong to a second account, so the caller's own allowance,
-- rate limits and fair-use budget never come into it: a refusal below can
-- only be the cap.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;
select no_plan();

create function pg_temp.student(p_id uuid) returns void language sql as $$
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
  ) values (
    p_id, '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', null, '', '{}', '{}', now(), now(), true
  );
$$;

-- N earlier calls by everyone else: what each reserved, what each really cost.
create function pg_temp.spent(
  p_kind text, p_n integer, p_state text, p_reserved integer, p_actual integer,
  p_ago interval default interval '10 minutes'
) returns void language sql as $$
  insert into public.ai_usage (user_id, kind, model, attempt_state,
                               reserved_cost_microusd, actual_cost_microusd, created_at)
  select 'b1000000-0000-4000-8000-000000000009', p_kind,
         case p_kind when 'grade' then 'claude-opus-5' else 'claude-haiku-4-5' end,
         p_state, p_reserved, p_actual, now() - p_ago
    from generate_series(1, p_n);
$$;

select pg_temp.student('b1000000-0000-4000-8000-000000000001');   -- Free, asking
select pg_temp.student('b1000000-0000-4000-8000-000000000002');   -- Plus, asking
select pg_temp.student('b1000000-0000-4000-8000-000000000009');   -- everyone else

insert into public.entitlements (user_id, tier, expires_at) values
  ('b1000000-0000-4000-8000-000000000002', 'plus', now() + interval '1 month');

-- Whatever the database already holds would count against the cap. The
-- transaction rolls back, so this empties nothing for real.
delete from public.ai_usage;

-- -------------------------------------------------------------------------
-- The figure. It is money, set by a person; a migration that moves it by
-- accident must fail here.

select results_eq(
  $$select key, int_value from public.app_config
     where key in ('ai_budget_per_day_microusd', 'ai_budget_per_hour_microusd')
     order by key$$,
  $$values ('ai_budget_per_day_microusd'::text, 1000000),
           ('ai_budget_per_hour_microusd'::text, 1000000)$$,
  'the AI spending cap is US$1 an hour and US$1 a day');

-- -------------------------------------------------------------------------
-- What counts.

select pg_temp.spent('breakdown', 1, 'completed', 30000, 2600);
select pg_temp.spent('breakdown', 1, 'failed', 30000, 200);
select pg_temp.spent('breakdown', 1, 'failed', 30000, null);
select pg_temp.spent('grade', 1, 'reserved', 450000, null);
select pg_temp.spent('grade', 1, 'completed', 450000, 90000, interval '2 days');
select is(private.ai_global_cost(interval '1 day'),
          (2600 + 200 + 30000 + 450000)::bigint,
          'a finished call counts its cost; a running or unmeasured one, its worst case');

-- -------------------------------------------------------------------------
-- The gate.

delete from public.ai_usage;
-- Sixty AI plans in the last hour: US$1.80 of worst cases, US$0.16 of money.
select pg_temp.spent('breakdown', 60, 'completed', 30000, 2600);
select lives_ok(
  $$select public.check_and_record_ai_usage(
      'b1000000-0000-4000-8000-000000000001', 'breakdown', 'claude-haiku-4-5')$$,
  'cheap finished calls do not fill the cap with their worst cases');

delete from public.ai_usage;
-- An ordinary day: a hundred AI plans and two markings, US$0.41 of money and
-- US$3.90 of worst cases. A marking reserves US$0.45 and still fits.
select pg_temp.spent('breakdown', 100, 'completed', 30000, 2600, interval '3 hours');
select pg_temp.spent('grade', 2, 'completed', 450000, 76000, interval '3 hours');
select lives_ok(
  $$select public.check_and_record_ai_usage(
      'b1000000-0000-4000-8000-000000000002', 'grade', 'claude-opus-5')$$,
  'a paying student can still be marked on an ordinary day');

delete from public.ai_usage;
-- US$0.98 of money in the last hour.
select pg_temp.spent('grade', 7, 'completed', 450000, 140000);
select throws_ok(
  $$select public.check_and_record_ai_usage(
      'b1000000-0000-4000-8000-000000000001', 'breakdown', 'claude-haiku-4-5')$$,
  'Q0004', 'GLOBAL_CAPACITY_REACHED',
  'money spent in the last hour stops AI at the cap');

delete from public.ai_usage;
-- The same US$0.98, two hours ago: outside the hour, inside the day.
select pg_temp.spent('grade', 7, 'completed', 450000, 140000, interval '2 hours');
select throws_ok(
  $$select public.check_and_record_ai_usage(
      'b1000000-0000-4000-8000-000000000001', 'breakdown', 'claude-haiku-4-5')$$,
  'Q0004', 'GLOBAL_CAPACITY_REACHED',
  'money spent earlier in the day stops AI at the cap');

delete from public.ai_usage;
-- Three markings still running. Nothing is measured yet; their worst case is
-- US$1.35, and a burst must not overshoot the cap while it waits to find out.
select pg_temp.spent('grade', 3, 'reserved', 450000, null);
select throws_ok(
  $$select public.check_and_record_ai_usage(
      'b1000000-0000-4000-8000-000000000001', 'breakdown', 'claude-haiku-4-5')$$,
  'Q0004', 'GLOBAL_CAPACITY_REACHED',
  'calls still running count their worst case');

select * from finish();
rollback;
