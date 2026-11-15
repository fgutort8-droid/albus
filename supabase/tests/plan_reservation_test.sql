-- What is set aside for an AI plan covers the most it can cost.
--
-- `check_and_record_ai_usage` admits a call against what it reserves, because
-- the real cost is only known afterwards. The plan call may now write 5,000
-- output tokens (`BREAKDOWN_MAX_TOKENS` in `_shared/anthropic.ts`), up from
-- 2,000, so that a rubric plan is not cut off by the reasoning Sonnet 5 does
-- before it answers. A reservation sized for 2,000 would have let a plan with
-- a large rubric cost more than was set aside for it, and so past a budget
-- that was nearly used up.

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
    'authenticated', 'authenticated', null, '', '{}', '{}', now(), now(), false
  );
$$;

select pg_temp.student('b2000000-0000-4000-8000-000000000001');   -- Plus, asking
select pg_temp.student('b2000000-0000-4000-8000-000000000009');   -- everyone else
insert into public.entitlements (user_id, tier, expires_at) values
  ('b2000000-0000-4000-8000-000000000001', 'plus', now() + interval '1 month');

-- Whatever the database already holds would count against the cap. The
-- transaction rolls back, so this empties nothing for real.
delete from public.ai_usage;

-- -------------------------------------------------------------------------
-- The figures, against the prices the ledger itself charges.

-- The largest rubric the app allows is forty criteria of 2,000 characters and
-- an 8,000-character body: about 24,000 tokens, 25,000 with the rest of the
-- prompt.
select cmp_ok(private.ai_reservation_cost('breakdown', 'claude-sonnet-5')::bigint, '>=',
              private.ai_metered_cost('claude-sonnet-5', 25000, 5000),
              'a rubric plan with the largest rubric and a full answer costs no more than is set aside');

-- No rubric reaches this model, so its prompt is the instructions and the task.
select cmp_ok(private.ai_reservation_cost('breakdown', 'claude-haiku-4-5')::bigint, '>=',
              private.ai_metered_cost('claude-haiku-4-5', 2000, 5000),
              'a plan without a rubric and a full answer costs no more than is set aside');

select is(private.ai_reservation_cost('grade', 'claude-opus-5'), 450000,
          'what is set aside for a rubric marking has not moved');
select is(private.ai_reservation_cost('grade', 'claude-sonnet-5'), 200000,
          'what is set aside for a marking without a rubric has not moved');

-- -------------------------------------------------------------------------
-- The gate. Paying students have spent US$0.92 of today's US$1.

insert into public.ai_usage (user_id, kind, model, attempt_state,
                             reserved_cost_microusd, actual_cost_microusd,
                             budget_pool, created_at)
select 'b2000000-0000-4000-8000-000000000009', 'grade', 'claude-opus-5',
       'completed', 450000, 115000, 'paid', now() - interval '2 hours'
  from generate_series(1, 8);

-- A rubric plan could cost up to US$0.10, which would pass the cap.
select throws_ok(
  $$select public.check_and_record_ai_usage(
      'b2000000-0000-4000-8000-000000000001', 'breakdown', 'claude-sonnet-5')$$,
  'Q0004', 'GLOBAL_CAPACITY_REACHED',
  'a rubric plan that could pass the cap is not started');

-- A plan without a rubric cannot cost more than US$0.03, and still fits.
select lives_ok(
  $$select public.check_and_record_ai_usage(
      'b2000000-0000-4000-8000-000000000001', 'breakdown', 'claude-haiku-4-5')$$,
  'a plan without a rubric still fits under the same cap');

select is(
  (select reserved_cost_microusd from public.ai_usage
    where user_id = 'b2000000-0000-4000-8000-000000000001' and kind = 'breakdown'),
  30000,
  'and it is recorded with what was set aside for it');

select * from finish();
rollback;
