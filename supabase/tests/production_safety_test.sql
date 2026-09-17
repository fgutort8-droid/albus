begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;
select no_plan();

-- These ids exist for one transaction only. The test always rolls back.
create function pg_temp.make_test_user(p_id uuid) returns void
language plpgsql
as $$
begin
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
  ) values (
    p_id, '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', null, '', '{}', '{}', now(), now(), true
  );
end;
$$;

select pg_temp.make_test_user('10000000-0000-4000-8000-000000000001');
select pg_temp.make_test_user('10000000-0000-4000-8000-000000000002');
select pg_temp.make_test_user('10000000-0000-4000-8000-000000000003');
select pg_temp.make_test_user('10000000-0000-4000-8000-000000000004');

select public.record_identity_link(
  '10000000-0000-4000-8000-000000000004',
  'device',
  repeat('a', 64)
);
select lives_ok(
  $$delete from auth.users where id = '10000000-0000-4000-8000-000000000004'$$,
  'deleting an anonymous account does not fail on retained abuse evidence'
);
select ok(
  exists (
    select 1 from public.identity_links l
     where l.user_id = '10000000-0000-4000-8000-000000000004'
       and l.kind = 'device' and l.hash = repeat('a', 64)
  ),
  'deleting an account cannot erase its 90-day device-farming signal'
);

create table public.default_private_probe (id integer);
select ok(
  not has_table_privilege('authenticated', 'public.default_private_probe', 'SELECT')
  and not has_table_privilege('authenticated', 'public.default_private_probe', 'INSERT'),
  'a future public table is private until a migration explicitly grants it'
);
drop table public.default_private_probe;

create function public.default_private_probe() returns integer
language sql as $$select 1$$;
select ok(
  not has_function_privilege('authenticated', 'public.default_private_probe()', 'EXECUTE'),
  'a future public function is private until explicitly granted'
);
drop function public.default_private_probe();

-- -------------------------------------------------------------------------
-- Privileges: a repackaged client still has only the public app surface.

select ok(
  not exists (
    select 1
      from information_schema.role_table_grants g
     where g.table_schema = 'public' and g.grantee = 'anon'
  ),
  'anon has no table grants in public'
);
select ok(not has_table_privilege('authenticated', 'public.ai_usage', 'SELECT'),
          'the app cannot read the raw AI cost ledger');
select ok(not has_table_privilege('authenticated', 'public.entitlements', 'SELECT'),
          'the app cannot read or infer raw subscription rows');
select ok(not has_table_privilege('authenticated', 'private.ai_tier_budgets', 'SELECT'),
          'the app cannot inspect or alter private financial loss ceilings');
select ok(not has_table_privilege('authenticated', 'public.assignments', 'INSERT'),
          'the app cannot bypass the controlled assignment RPC');
select ok(not has_table_privilege('authenticated', 'public.assignments', 'UPDATE'),
          'the app cannot mutate server assignment state directly');
select ok(has_table_privilege('authenticated', 'public.assignments', 'DELETE'),
          'the owner-scoped assignment delete used by the app remains available');
select ok(not has_table_privilege('authenticated', 'public.subtasks', 'INSERT'),
          'the app cannot manufacture remote plan rows');
select ok(not has_table_privilege('authenticated', 'public.plan_sessions', 'SELECT'),
          'the unused remote session table is outside the client surface');
select ok(not has_table_privilege('authenticated', 'public.completion_logs', 'INSERT'),
          'the unused remote calibration table is outside the client surface');

select ok(not has_function_privilege(
  'authenticated', 'public.check_and_record_ai_usage(uuid,text,text)', 'EXECUTE'),
  'only the server can reserve paid AI work');
select ok(has_function_privilege(
  'service_role', 'public.check_and_record_ai_usage(uuid,text,text)', 'EXECUTE'),
  'the server can reserve paid AI work');
select ok(not has_function_privilege(
  'authenticated', 'public.finalize_ai_usage(uuid,text,integer,integer,text,integer,integer)', 'EXECUTE'),
  'the app cannot forge token counts or completion state');
select ok(not has_function_privilege(
  'authenticated', 'public.check_api_request_rate(uuid,text)', 'EXECUTE'),
  'the app cannot reset or manufacture request windows');
select ok(has_function_privilege(
  'service_role', 'public.check_api_request_rate(uuid,text)', 'EXECUTE'),
  'the server can enforce request windows');
select ok(not has_function_privilege(
  'authenticated',
  'public.apply_subscription_state(text,uuid,text,text,text,timestamptz,timestamptz,timestamptz,text,timestamptz)',
  'EXECUTE'),
  'the app cannot grant itself a subscription');
select ok(has_function_privilege(
  'service_role',
  'public.apply_subscription_state(text,uuid,text,text,text,timestamptz,timestamptz,timestamptz,text,timestamptz)',
  'EXECUTE'),
  'the signed webhook can apply a subscription');
select ok(has_function_privilege(
  'authenticated',
  'public.create_assignment_with_plan(text,text,timestamptz,integer,jsonb,uuid,uuid,text,uuid,text)',
  'EXECUTE'),
  'the controlled assignment RPC remains callable');
select ok(has_function_privilege(
  'authenticated', 'public.upsert_rubric(uuid,text,text,text,integer,jsonb)', 'EXECUTE'),
  'the controlled rubric RPC remains callable');
select ok(has_function_privilege(
  'authenticated', 'public.create_course(text,text,text,text,smallint)', 'EXECUTE'),
  'the controlled course RPC remains callable');

-- The task-type list is written in three places: this constraint, TASK_TYPES
-- in the breakdown Edge Function, and TaskType in the iOS app. They have
-- drifted before. This is the only one of the three that can be checked
-- against the real database, so it is where the full expected set is pinned.
select ok(
  (select bool_and(pg_get_constraintdef(con.oid) like '%' || t.name || '%')
     from pg_constraint con
     join pg_class c on c.oid = con.conrelid
     cross join (values
       ('essay'),('problem_set'),('lab_report'),('reading'),
       ('revision'),('project'),('presentation'),('other'),
       ('internal_assessment'),('extended_essay'),
       ('tok_essay'),('tok_exhibition'),
       ('mock_exam'),('final_exam')
     ) as t(name)
    where c.relname = 'assignments'
      and con.conname = 'assignments_task_type_check'),
  'assignments.task_type accepts all fourteen known types'
);

select is(
  (select count(*)::integer from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'check_and_record_ai_usage'
      and pg_get_function_identity_arguments(p.oid) = 'p_kind text, p_model text'),
  0,
  'the obsolete client-callable quota function was removed'
);
select is(
  (select count(*)::integer from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'record_ai_usage_tokens'),
  0,
  'the obsolete client token writer was removed'
);
select is(
  (select count(*)::integer from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = 'apply_subscription_state'
      and p.pronargs = 8),
  0,
  'the obsolete unsigned-subscription RPC was removed'
);
select ok(
  not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity
  ),
  'every public table has RLS enabled'
);
select ok(
  not exists (
    select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      cross join lateral unnest(coalesce(p.proconfig, array[]::text[])) cfg
     where p.prosecdef and n.nspname in ('public', 'private')
       and cfg like 'search_path=%public%'
  ),
  'no privileged function resolves objects through the public schema'
);

-- -------------------------------------------------------------------------
-- RLS and controlled writes with two real JWT identities.

insert into public.courses (id, user_id, display_name, color_key) values
  ('11000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001', 'Alice Biology', 'green'),
  ('11000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000002', 'Bob History', 'amber');
insert into public.assignments (
  id, user_id, course_id, title, task_type, deadline, estimated_minutes
) values
  ('12000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
   '11000000-0000-4000-8000-000000000001', 'Alice essay', 'essay', now() + interval '7 days', 60),
  ('12000000-0000-4000-8000-000000000002', '10000000-0000-4000-8000-000000000002',
   '11000000-0000-4000-8000-000000000002', 'Bob essay', 'essay', now() + interval '7 days', 60);
insert into public.rubrics (id, user_id, name, source, total_marks) values
  ('13000000-0000-4000-8000-000000000099',
   '10000000-0000-4000-8000-000000000002', 'Bob rubric', 'custom', 10);
insert into public.rubric_items
  (user_id, rubric_id, code, name, marks, ordinal) values
  ('10000000-0000-4000-8000-000000000002',
   '13000000-0000-4000-8000-000000000099', 'A', 'Bob criterion', 10, 0);

set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
select is((select count(*) from public.assignments), 1::bigint,
          'RLS shows Alice only her own assignment');
select is((select count(*) from public.assignments
            where id = '12000000-0000-4000-8000-000000000002'), 0::bigint,
          'a known foreign assignment id still reveals no row');
delete from public.assignments where id = '12000000-0000-4000-8000-000000000002';
select is(public.my_tier(), 'free', 'client state cannot turn a Free account into Pro');

select throws_ok(
  $$select public.create_assignment_with_plan(
      'Foreign course', 'essay', now() + interval '7 days', 60,
      '[{"title":"Draft","estimated_minutes":60}]'::jsonb,
      '11000000-0000-4000-8000-000000000002', null, null, null, 'normal')$$,
  '42501'::character(5), 'COURSE_NOT_YOURS',
  'the SECURITY DEFINER assignment RPC rejects another user''s course'
);

select lives_ok($$
  do $body$
  declare i integer;
  begin
    for i in 1..4 loop
      perform public.create_assignment_with_plan(
        'Allowed ' || i, 'essay', now() + interval '7 days', 60,
        '[{"title":"Draft","estimated_minutes":60}]'::jsonb,
        '11000000-0000-4000-8000-000000000001', null, null, null, 'normal');
    end loop;
  end
  $body$
$$, 'Free can create up to five active assignments through the RPC');
select throws_ok(
  $$select public.create_assignment_with_plan(
      'Sixth', 'essay', now() + interval '7 days', 60,
      '[{"title":"Draft","estimated_minutes":60}]'::jsonb,
      '11000000-0000-4000-8000-000000000001', null, null, null, 'normal')$$,
  'Q0001'::character(5), 'PLAN_TASK_LIMIT_REACHED',
  'the Free active-task limit holds inside the database'
);

select lives_ok($$
  do $body$
  declare i integer;
  begin
    for i in 1..3 loop
      perform public.upsert_rubric(
        ('13000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid,
        'Rubric ' || i, 'custom', null, 10,
        '[{"code":"A","name":"Quality","marks":10}]'::jsonb);
    end loop;
  end
  $body$
$$, 'Free can save exactly three rubrics through the RPC');
select throws_ok(
  $$select public.upsert_rubric(
      '13000000-0000-4000-8000-000000000004', 'Fourth', 'custom', null, 10,
      '[{"code":"A","name":"Quality","marks":10}]'::jsonb)$$,
  'Q0011'::character(5), 'RUBRIC_PLAN_LIMIT',
  'the Free rubric limit holds inside the database'
);
select lives_ok(
  $$select public.upsert_rubric(
      '13000000-0000-4000-8000-000000000001', 'Edited first rubric',
      'custom', null, 10,
      '[{"code":"A","name":"Edited quality","marks":10}]'::jsonb)$$,
  'editing an owned rubric still works when the plan is exactly full'
);
select throws_ok(
  $$select public.upsert_rubric(
      '13000000-0000-4000-8000-000000000099', 'Stolen rubric',
      'custom', null, 10,
      '[{"code":"A","name":"Replaced criterion","marks":10}]'::jsonb)$$,
  '42501'::character(5), 'RUBRIC_NOT_YOURS',
  'the privileged rubric RPC rejects another user''s known rubric id'
);
select throws_ok(
  $$select public.upsert_rubric(
      '13000000-0000-4000-8000-000000000001', repeat('x', 201),
      'custom', null, 10, '[]'::jsonb)$$,
  '22023'::character(5), 'RUBRIC_NAME_INVALID',
  'direct RPC calls cannot persist unbounded rubric names'
);
reset role;
select is((select count(*) from public.assignments
            where id = '12000000-0000-4000-8000-000000000002'), 1::bigint,
          'Alice could not delete Bob''s assignment');
select is((select name from public.rubrics
            where id = '13000000-0000-4000-8000-000000000099'), 'Bob rubric',
          'a rejected foreign rubric write preserves the owner''s row');
select is((select name from public.rubric_items
            where rubric_id = '13000000-0000-4000-8000-000000000099'), 'Bob criterion',
          'a rejected foreign rubric write preserves the owner''s criteria');

select throws_ok(
  $$insert into public.gradings
      (user_id, assignment_id, model, input_chars, basis, work_title)
    values
      ('10000000-0000-4000-8000-000000000001',
       '12000000-0000-4000-8000-000000000002',
       'claude-sonnet-5', 100, 'blind', 'Foreign assignment')$$,
  '42501'::character(5), 'ASSIGNMENT_NOT_YOURS',
  'a service-role grading cannot be attached to another user''s assignment'
);
select lives_ok(
  $$insert into public.gradings
      (user_id, assignment_id, model, input_chars, basis, work_title)
    values
      ('10000000-0000-4000-8000-000000000001',
       '12000000-0000-4000-8000-000000000001',
       'claude-sonnet-5', 100, 'blind', 'Owned assignment')$$,
  'a grading can still be attached to its owner''s assignment'
);
select lives_ok(
  $$insert into public.gradings
      (user_id, assignment_id, model, input_chars, basis, work_title)
    values
      ('10000000-0000-4000-8000-000000000001',
       null, 'claude-sonnet-5', 100, 'blind', 'Loose work')$$,
  'loose work without an assignment remains gradable'
);

-- -------------------------------------------------------------------------
-- Request, attempt, allowance, and cost are four different counters.

select throws_ok(
  $$select public.check_and_record_ai_usage(
      '10000000-0000-4000-8000-000000000001', 'grade', 'claude-sonnet-5')$$,
  'Q0007'::character(5), 'PLAN_UPGRADE_REQUIRED',
  'Free cannot buy a grading by calling the backend directly'
);

update public.app_config set int_value = 2 where key = 'api_requests_per_minute';
update public.app_config set int_value = 3 where key = 'api_requests_per_hour';
select lives_ok($$
  do $body$ begin
    perform public.check_api_request_rate('10000000-0000-4000-8000-000000000001', 'grade');
    perform public.check_api_request_rate('10000000-0000-4000-8000-000000000001', 'grade');
  end $body$
$$, 'ordinary requests fit inside the outer request window');
select throws_ok(
  $$select public.check_api_request_rate(
      '10000000-0000-4000-8000-000000000001', 'grade')$$,
  'Q0014'::character(5), 'API_RATE_LIMIT',
  'malformed or ineligible traffic is still rate-limited before AI quota'
);

select lives_ok($$
  do $body$
  declare i integer; usage uuid;
  begin
    for i in 1..6 loop
      usage := public.check_and_record_ai_usage(
        '10000000-0000-4000-8000-000000000001', 'breakdown', 'claude-haiku-4-5');
      perform public.finalize_ai_usage(usage, 'failed', 100, 20, 'PROVIDER_FAILED');
    end loop;
  end
  $body$
$$, 'six failed generations are recorded as attempts');
select is(public.ai_spend_count(
            '10000000-0000-4000-8000-000000000001', 'breakdown', interval '1 day'),
          0, 'failed work does not consume purchased allowance');
select is(private.ai_attempt_count(
            '10000000-0000-4000-8000-000000000001', 'breakdown', interval '1 hour'),
          6, 'failed work still consumes the abuse-rate window');
select throws_ok(
  $$select public.check_and_record_ai_usage(
      '10000000-0000-4000-8000-000000000001', 'breakdown', 'claude-haiku-4-5')$$,
  'Q0002'::character(5), 'RATE_LIMIT_HOURLY',
  'repeating expensive failures cannot run forever'
);

create temporary table test_usage (id uuid primary key);
insert into test_usage select public.check_and_record_ai_usage(
  '10000000-0000-4000-8000-000000000002', 'breakdown', 'claude-haiku-4-5');
select ok(public.finalize_ai_usage((select id from test_usage), 'completed', 10, 20, null),
          'a reservation can be finalized once');
select ok(not public.finalize_ai_usage((select id from test_usage), 'failed', 1, 1, 'REPLAY'),
          'replaying finalization cannot rewrite cost or outcome');
select is((select actual_cost_microusd from public.ai_usage
            where id = (select id from test_usage)), 110,
          'actual cost is derived from server-owned model prices');

create temporary table test_unpriced_usage (id uuid primary key);
with inserted as (
  insert into public.ai_usage (
    user_id, kind, model, attempt_state, reserved_cost_microusd
  ) values (
    '10000000-0000-4000-8000-000000000002', 'breakdown',
    'claude-unpriced-test', 'reserved', 500000
  ) returning id
)
insert into test_unpriced_usage select id from inserted;
-- Finalise in its own statement. Reading `ai_usage` inside the same statement
-- that calls `finalize_ai_usage` returns the pre-update snapshot — the row is
-- read as it stood when the statement began, so the assertion sees NULL rather
-- than the cost the function just wrote.
select ok(
  public.finalize_ai_usage(
    (select id from test_unpriced_usage), 'completed', 10, 20, null
  ),
  'an unpriced model still finalises'
);
select is(
  (select actual_cost_microusd from public.ai_usage
    where id = (select id from test_unpriced_usage)),
  2500,
  'an unpriced model warns and retains the conservative 50/100 token rates'
);
select ok(
  exists (
    select 1 from pg_constraint c
     where c.conrelid = 'public.ai_usage'::regclass
       and c.conname = 'ai_usage_reserved_cost_positive'
       and pg_get_constraintdef(c.oid) like '%reserved_cost_microusd > 0%'
  ),
  'zero-cost AI reservations cannot be inserted after the historical backfill'
);

-- A completed call pays its measured price, while an in-flight or unknown call
-- retains its conservative reservation. This lets ordinary inexpensive calls
-- fit without giving a crashed/replayed provider call a free path.
update private.ai_tier_budgets
   set rolling_30d_cost_microusd = 100000
 where tier = 'free';
insert into public.ai_usage (
  user_id, kind, model, attempt_state, finished_at,
  reserved_cost_microusd, actual_cost_microusd
) values (
  '10000000-0000-4000-8000-000000000003', 'breakdown', 'claude-sonnet-5',
  'completed', now(), 450000, 65000
);
select is(private.ai_account_cost(
            '10000000-0000-4000-8000-000000000003', interval '30 days'),
          65000::bigint,
          'terminal usage counts measured server-priced cost, not its old reservation');
insert into test_usage select public.check_and_record_ai_usage(
  '10000000-0000-4000-8000-000000000003', 'breakdown', 'claude-haiku-4-5');
select is(private.ai_account_cost(
            '10000000-0000-4000-8000-000000000003', interval '30 days'),
          95000::bigint,
          'an in-flight call keeps its conservative reservation');
select throws_ok(
  $$select public.check_and_record_ai_usage(
      '10000000-0000-4000-8000-000000000003', 'breakdown', 'claude-haiku-4-5')$$,
  'Q0017'::character(5), 'FAIR_USE_REACHED',
  'one account cannot spend beyond its private rolling loss ceiling'
);

-- -------------------------------------------------------------------------
-- Hostile telemetry stays useful but cannot grow without bound.

select lives_ok($$
  do $body$
  declare i integer;
  begin
    for i in 1..10 loop
      perform public.record_identity_link(
        '10000000-0000-4000-8000-000000000001', 'device',
        lpad(to_hex(i), 64, 'a'));
    end loop;
  end
  $body$
$$, 'hostile rotating device ids do not fail the product request');
select is((select count(*) from public.identity_links
            where user_id = '10000000-0000-4000-8000-000000000001'
              and kind = 'device'), 8::bigint,
          'only eight device observations can be stored per account');

select lives_ok($$
  do $body$
  declare i integer;
  begin
    for i in 1..55 loop
      perform public.log_security_event(
        '10000000-0000-4000-8000-000000000001', 'ratelimit.hit', 'warn',
        null, null, jsonb_build_object('code', 'TEST', 'n', i));
    end loop;
  end
  $body$
$$, 'security logging remains best-effort under a denial flood');
select is((select count(*) from public.security_events
            where user_id = '10000000-0000-4000-8000-000000000001'), 50::bigint,
          'a denial flood is capped to fifty audit rows per user per hour');

-- -------------------------------------------------------------------------
-- Account farming needs independent signals; one school network is not proof.

select lives_ok($$
  do $body$
  declare i integer; uid uuid;
  begin
    for i in 1..6 loop
      uid := ('20000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid;
      perform pg_temp.make_test_user(uid);
      perform public.record_identity_link(uid, 'device', repeat('d', 64));
      perform public.record_identity_link(uid, 'ip_prefix', repeat('e', 64));
    end loop;
  end
  $body$
$$, 'six farm-shaped accounts can be modelled without raw identifiers');
select is((select r.band from public.account_risk(
            '20000000-0000-4000-8000-000000000001') r), 'severe',
          'multiple accounts plus independent device and network signals are severe');
select throws_ok(
  $$select public.check_and_record_ai_usage(
      '20000000-0000-4000-8000-000000000001', 'breakdown', 'claude-haiku-4-5')$$,
  'Q0010'::character(5), 'ABUSE_SUSPECTED',
  'a severe farm-shaped account cannot spend on AI'
);

select lives_ok($$
  do $body$
  declare i integer; uid uuid;
  begin
    for i in 1..21 loop
      uid := ('30000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid;
      perform pg_temp.make_test_user(uid);
      perform public.record_identity_link(uid, 'ip_prefix', repeat('f', 64));
    end loop;
  end
  $body$
$$, 'a shared-school-network scenario can be modelled');
select isnt((select r.band from public.account_risk(
              '30000000-0000-4000-8000-000000000001') r), 'severe',
            'one busy network alone never blocks a student');

insert into public.entitlements (user_id, tier, expires_at)
values ('20000000-0000-4000-8000-000000000002', 'pro', now() + interval '1 month')
on conflict (user_id) do update set tier = excluded.tier, expires_at = excluded.expires_at;
select is((select r.band from public.account_risk(
            '20000000-0000-4000-8000-000000000002') r), 'elevated',
          'a verified payment caps heuristic risk instead of locking out a customer');

-- -------------------------------------------------------------------------
-- Subscription state is signed outside SQL and still fails closed inside it.

insert into public.subscription_products (product_id, tier) values
  ('albus.plus.monthly', 'plus'),
  ('albus.pro.monthly', 'pro');

-- Sandbox purchases unlock a plan only while `allow_sandbox_subscriptions`
-- is on. It is on in production, because App Review buys in the sandbox
-- (payments_test.sql covers that side). The switch itself must still work.
update public.app_config set int_value = 0 where key = 'allow_sandbox_subscriptions';
select is(public.apply_subscription_state(
  'sandbox-a', '10000000-0000-4000-8000-000000000001', 'sandbox-tx',
  'albus.plus.monthly', 'Sandbox', now(), now() + interval '1 month', null,
  'event-sandbox', now()), 'sandbox_ignored',
  'with the switch off, a free sandbox purchase cannot grant production access');
select is(public.effective_tier('10000000-0000-4000-8000-000000000001'), 'free',
          'the ignored sandbox event leaves the user Free');
update public.app_config set int_value = 1 where key = 'allow_sandbox_subscriptions';
select is(public.apply_subscription_state(
  'unknown-a', '10000000-0000-4000-8000-000000000001', 'unknown-tx',
  'attacker.pro.forever', 'Production', now(), now() + interval '10 years', null,
  'event-unknown', now()), 'unknown_product',
  'an unknown product id grants nothing');

select is(public.apply_subscription_state(
  'paid-a', '10000000-0000-4000-8000-000000000001', 'paid-a-1',
  'albus.plus.monthly', 'Production', now(), now() + interval '1 month', null,
  'event-paid-a-1', now()), 'active_plus',
  'an allowlisted production purchase grants the mapped tier');
select is(public.effective_tier('10000000-0000-4000-8000-000000000001'), 'plus',
          'the production Plus entitlement is active');
select is(public.apply_subscription_state(
  'paid-a', '10000000-0000-4000-8000-000000000001', 'paid-a-1',
  'albus.plus.monthly', 'Production', now(), now() + interval '1 month', null,
  'event-paid-a-1', now()), 'stale',
  'replaying the same event cannot grant twice or rewrite state');
select is(public.apply_subscription_state(
  'paid-a', '10000000-0000-4000-8000-000000000001', 'paid-a-old',
  'albus.plus.monthly', 'Production', now() - interval '2 days', now() - interval '1 day', now(),
  'event-paid-a-old', now() - interval '1 day'), 'stale',
  'an out-of-order revocation cannot overwrite a newer purchase');
select is(public.effective_tier('10000000-0000-4000-8000-000000000001'), 'plus',
          'the stale revocation leaves the current entitlement intact');

select is(public.apply_subscription_state(
  'paid-a-pro', '10000000-0000-4000-8000-000000000001', 'paid-a-pro-1',
  'albus.pro.monthly', 'Production', now(), now() + interval '2 months', null,
  'event-paid-a-pro-1', now() + interval '2 seconds'), 'active_pro',
  'an upgrade raises the account to the highest active verified plan');
select is(public.apply_subscription_state(
  'paid-a', '10000000-0000-4000-8000-000000000001', 'paid-a-2',
  'albus.plus.monthly', 'Production', now(), now() + interval '1 month', null,
  'event-paid-a-2', now() + interval '3 seconds'), 'active_pro',
  'a later renewal from an overlapping lower plan cannot downgrade Pro');
select is(public.apply_subscription_state(
  'paid-a', '10000000-0000-4000-8000-000000000001', 'paid-a-expired',
  'albus.plus.monthly', 'Production', now(), now(), now(),
  'event-paid-a-expired', now() + interval '4 seconds'), 'active_pro',
  'one transaction expiring cannot revoke another active transaction');
select is(public.apply_subscription_state(
  'paid-a', '10000000-0000-4000-8000-000000000001', 'paid-a-same-time',
  'albus.plus.monthly', 'Production', now(), now() + interval '1 month', null,
  'event-paid-a-same-time',
  (select last_event_at from public.subscription_transactions
    where original_transaction_id = 'paid-a')), 'active_pro',
  'a distinct event sharing a millisecond is processed rather than mistaken for a replay');
select is(public.effective_tier('10000000-0000-4000-8000-000000000001'), 'pro',
          'the independently active Pro transaction remains authoritative');
select is(public.apply_subscription_state(
  'paid-a', '10000000-0000-4000-8000-000000000002', 'stolen',
  'albus.pro.monthly', 'Production', now(), now() + interval '1 month', null,
  'event-conflict', now() + interval '5 seconds'), 'conflict',
  'a subscription already linked to one user cannot be stolen by another');
select is(public.effective_tier('10000000-0000-4000-8000-000000000002'), 'free',
          'the conflicting user receives no entitlement');

select is(public.apply_subscription_state(
  'paid-b', '10000000-0000-4000-8000-000000000002', 'paid-b-1',
  'albus.pro.monthly', 'Production', now(), now() + interval '1 month', null,
  'event-paid-b-1', now()), 'active_pro',
  'the product map can grant Pro rather than treating every product as Plus');
select is(public.effective_tier('10000000-0000-4000-8000-000000000002'), 'pro',
          'the Pro entitlement resolves server-side');

update public.subscription_products set active = false
 where product_id = 'albus.pro.monthly';
select is(public.apply_subscription_state(
  'paid-b', '10000000-0000-4000-8000-000000000002', 'paid-b-2',
  'albus.pro.monthly', 'Production', now(), now() + interval '1 month', null,
  'event-paid-b-2',
  (select last_event_at + interval '1 second'
     from public.subscription_transactions where original_transaction_id = 'paid-b')),
  'active_pro',
  'retiring a product does not reject an existing subscriber''s renewal');
select is(public.apply_subscription_state(
  'paid-a', '10000000-0000-4000-8000-000000000001', 'paid-a-3',
  'albus.plus.monthly', 'Production', now(), now() + interval '1 month', null,
  'event-paid-a-3',
  (select last_event_at + interval '1 second'
     from public.subscription_transactions where original_transaction_id = 'paid-a')),
  'active_pro',
  'another transaction cannot erase a paid entitlement for a retired product');
update public.subscription_products set active = true
 where product_id = 'albus.pro.monthly';

select is(public.apply_subscription_state(
  'no-expiry', '10000000-0000-4000-8000-000000000003', 'no-expiry-1',
  'albus.pro.monthly', 'Production', now(), null, null,
  'event-no-expiry', now()), 'inactive',
  'a missing expiry fails closed instead of meaning lifetime access');
select is(public.effective_tier('10000000-0000-4000-8000-000000000003'), 'free',
          'a missing expiry leaves the account Free');

-- Deleting an account must not erase what it cost.
--
-- `docs/security-model.md` § 7 promises successful AI rows survive for cost
-- reconciliation. That promise was false while the foreign key cascaded, and a
-- cascade is a one-character change away from coming back — so assert the
-- delete rule itself rather than the paragraph.
select is(
  (select case con.confdeltype when 'n' then 'SET NULL' when 'c' then 'CASCADE'
                               when 'a' then 'NO ACTION' when 'r' then 'RESTRICT'
                               when 'd' then 'SET DEFAULT' end
     from pg_constraint con
    where con.conrelid = 'public.ai_usage'::regclass
      and con.contype = 'f'
      and con.conname = 'ai_usage_user_id_fkey'),
  'SET NULL',
  'deleting a user anonymises its AI cost rows rather than deleting them');

-- SET NULL on a NOT NULL column raises instead of anonymising, which would turn
-- account deletion into an error rather than the silent data loss it replaces.
select ok(
  not (select attnotnull from pg_attribute
        where attrelid = 'public.ai_usage'::regclass and attname = 'user_id'),
  'ai_usage.user_id is nullable, so SET NULL can actually fire');

-- The orphaned row must be invisible through the API. Both policies compare
-- `auth.uid() = user_id`, and NULL = uid is NULL rather than true.
select is(
  (select count(*)::int from pg_policy
    where polrelid = 'public.ai_usage'::regclass
      and pg_get_expr(polqual, polrelid) not like '%user_id%'),
  0,
  'every ai_usage policy still scopes by user_id, so a null row belongs to nobody');

-- A rubric must not mix marked and unmarked criteria.
--
-- The prompt renders a criterion's marks only when it has them, so a component
-- where A is "6 marks" and B is bare reads as though B is worth nothing. Where
-- the split is unverified we publish every criterion unmarked — names ground the
-- plan, and no mark is claimed. This asserts that all-or-nothing rule, because
-- the failure it prevents is a student optimising away from an uncosted
-- criterion.
select is(
  (select count(*)::int from (
     select rc.assessment_type_id
       from public.rubric_criteria rc
      group by rc.assessment_type_id
     having count(rc.marks) > 0 and count(rc.marks) < count(*)
   ) mixed),
  0,
  'no assessment type mixes criteria that have marks with criteria that do not');

-- Where marks are published at all, every criterion carries one, so the sum of
-- a component's criteria is a number a student can actually be told.
select ok(
  not exists (
    select 1 from public.rubric_criteria rc
     where rc.marks is not null and rc.marks <= 0
  ),
  'a published criterion mark is always positive');

-- Cached tokens are billed, and were being counted as zero.
--
-- `usage.input_tokens` from the Anthropic API excludes both cache fields, so a
-- ledger fed only input+output cannot see them. A cache write costs MORE per
-- token than fresh input (1.25x), which is why the blind spot was worst exactly
-- where the money was.
select is(
  private.ai_metered_cost('claude-sonnet-5', 1000, 100, 1000, 10000)::bigint,
  7500::bigint,
  'cache writes price at 1.25x input and reads at 0.10x');

-- Haiku's input rate is 1 micro-USD per token, so `rate / 10` for a cache read
-- truncates to zero in integer arithmetic. Multiplying before dividing is the
-- only reason the cheapest model does not price its cached tokens at nothing.
select is(
  private.ai_metered_cost('claude-haiku-4-5', 0, 0, 0, 10000)::bigint,
  1000::bigint,
  'the cheapest model still prices cache reads above zero');

select ok(
  private.ai_metered_cost('claude-opus-5', 0, 0, 1000, 0)
    > private.ai_metered_cost('claude-opus-5', 1000, 0, 0, 0),
  'a cache write costs more than the same number of ordinary input tokens');

-- Uncached behaviour must be byte-identical to before this change.
select is(
  private.ai_metered_cost('claude-sonnet-5', 1412, 316)::bigint,
  5984::bigint,
  'pricing a call with no cache involvement is unchanged');

-- End to end: the tokens have to survive the reservation -> finalise round trip
-- and land in a cost, not just price correctly in isolation.
create temporary table test_cache_usage (id uuid primary key);
insert into test_cache_usage select public.check_and_record_ai_usage(
  '10000000-0000-4000-8000-000000000002', 'breakdown', 'claude-haiku-4-5');
-- Split from the assertion deliberately: a subquery reading the row in the same
-- statement that mutates it sees the pre-update snapshot.
select public.finalize_ai_usage(
  (select id from test_cache_usage), 'completed', 10, 20, null, 100, 1000);
-- 10*1 + 20*5 + (100*1*125/100 = 125) + (1000*1*10/100 = 100) = 335
select is(
  (select actual_cost_microusd from public.ai_usage
    where id = (select id from test_cache_usage)),
  335,
  'cached tokens reach the ledger and are charged');
select is(
  (select cache_write_tokens || '/' || cache_read_tokens from public.ai_usage
    where id = (select id from test_cache_usage)),
  '100/1000',
  'cache token counts are stored, not just folded into a total');

select * from finish();
rollback;
