-- Payments, asserted where they are enforced.
--
-- What a real purchase needs before the first one happens: the products are
-- mapped, Apple's test purchases unlock the plan (App Review buys in the
-- sandbox), a restore moves the plan to the new install, income is recorded
-- honestly, and free and paying accounts spend from separate fuses so the free
-- ones can never use up what paying students need.

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

-- N finished calls by one account, in one pool, ten minutes ago: inside the
-- hour and the day, outside the five-minute burst window.
create function pg_temp.spent(
  p_uid uuid, p_pool text, p_n integer, p_actual integer
) returns void language sql as $$
  insert into public.ai_usage (user_id, kind, model, attempt_state,
                               reserved_cost_microusd, actual_cost_microusd,
                               budget_pool, created_at)
  select p_uid, 'breakdown', 'claude-haiku-4-5', 'completed', 30000, p_actual,
         p_pool, now() - interval '10 minutes'
    from generate_series(1, p_n);
$$;

create function pg_temp.proceeds(
  p_id text, p_environment text, p_net bigint, p_ago interval
) returns void language sql as $$
  insert into public.subscription_revenue
    (event_id, event_type, environment, net_microusd, occurred_at)
  values (p_id, 'RENEWAL', p_environment, p_net, now() - p_ago);
$$;

select pg_temp.student('d1000000-0000-4000-8000-000000000001');   -- bought, old install
select pg_temp.student('d1000000-0000-4000-8000-000000000002');   -- same student, new install
select pg_temp.student('d1000000-0000-4000-8000-000000000004');   -- a Plus student
select pg_temp.student('d1000000-0000-4000-8000-000000000005');   -- a Free student
select pg_temp.student('d1000000-0000-4000-8000-000000000009');   -- other free accounts

-- Whatever the database already holds would count. The transaction rolls
-- back, so this empties nothing for real.
delete from public.ai_usage;
delete from public.subscription_revenue;

-- -------------------------------------------------------------------------
-- The products. A purchase nobody mapped grants nothing while Apple keeps the
-- money.

select results_eq(
  $$select product_id, tier from public.subscription_products
     where product_id like 'com.felipegutierrez.albus.%' and active
     order by product_id$$,
  $$values ('com.felipegutierrez.albus.plus.annual',  'plus'),
           ('com.felipegutierrez.albus.plus.monthly', 'plus'),
           ('com.felipegutierrez.albus.pro.annual',   'pro'),
           ('com.felipegutierrez.albus.pro.monthly',  'pro')$$,
  'the four App Store products map to their plans');

-- -------------------------------------------------------------------------
-- Apple's test purchases. App Review pays with a sandbox account against this
-- backend; if nothing unlocks, the build is rejected.

select is((select int_value from public.app_config
            where key = 'allow_sandbox_subscriptions'), 1,
          'sandbox purchases are allowed, for App Review and TestFlight');
select is(public.apply_subscription_state(
  'sbx-1', 'd1000000-0000-4000-8000-000000000001', 'sbx-1-tx',
  'com.felipegutierrez.albus.plus.monthly', 'Sandbox', now(),
  now() + interval '5 minutes', null, 'evt-sbx-1', now()), 'active_plus',
  'a sandbox purchase unlocks the plan');
select is(public.effective_tier('d1000000-0000-4000-8000-000000000001'), 'plus',
          'the reviewer sees Plus');

update public.app_config set int_value = 0 where key = 'allow_sandbox_subscriptions';
select is(public.apply_subscription_state(
  'sbx-2', 'd1000000-0000-4000-8000-000000000005', 'sbx-2-tx',
  'com.felipegutierrez.albus.plus.monthly', 'Sandbox', now(),
  now() + interval '5 minutes', null, 'evt-sbx-2', now()), 'sandbox_ignored',
  'with the switch off, a new sandbox purchase is ignored');
select is(private.recompute_entitlement('d1000000-0000-4000-8000-000000000001'), 'inactive',
          'and an existing sandbox purchase stops counting');
select is(public.effective_tier('d1000000-0000-4000-8000-000000000001'), 'free',
          'so the account is Free again');
update public.app_config set int_value = 1 where key = 'allow_sandbox_subscriptions';
select is(private.recompute_entitlement('d1000000-0000-4000-8000-000000000001'), 'active_plus',
          'switching it back on restores the sandbox plan');

-- -------------------------------------------------------------------------
-- Restores. Accounts start anonymous, so a new phone is a new account, and
-- RevenueCat moves the purchase when the student taps Restore.

select is(public.apply_subscription_state(
  'prod-1', 'd1000000-0000-4000-8000-000000000001', 'prod-1-a',
  'com.felipegutierrez.albus.pro.monthly', 'Production', now(),
  now() + interval '1 month', null, 'evt-prod-1', now()), 'active_pro',
  'the student buys Pro on the old install');

-- RevenueCat can deliver the restored purchase's renewal before the transfer.
select is(public.apply_subscription_state(
  'prod-1', 'd1000000-0000-4000-8000-000000000002', 'prod-1-b',
  'com.felipegutierrez.albus.pro.monthly', 'Production', now(),
  now() + interval '2 months', null, 'evt-prod-2', now() + interval '1 second'), 'conflict',
  'a renewal naming another account, before any transfer, is a conflict');
select is(public.effective_tier('d1000000-0000-4000-8000-000000000002'), 'free',
          'which grants that account nothing');
select is((select user_id from public.subscription_transactions
            where original_transaction_id = 'prod-1'),
          'd1000000-0000-4000-8000-000000000001'::uuid,
          'and does not move the purchase');
select is((select expires_at from public.subscription_transactions
            where original_transaction_id = 'prod-1'),
          now() + interval '2 months',
          'but the renewal itself is kept, not dropped');
select is((select expires_at from public.entitlements
            where user_id = 'd1000000-0000-4000-8000-000000000001'),
          now() + interval '2 months',
          'and the account that owns it gets the longer plan');

-- The old install used this week's five markings, and planned something long
-- before any limit looks.
insert into public.ai_usage (user_id, kind, model, attempt_state,
                             reserved_cost_microusd, actual_cost_microusd,
                             budget_pool, created_at)
select 'd1000000-0000-4000-8000-000000000001'::uuid, 'grade', 'claude-opus-5',
       'completed', 450000, 100000, 'paid', now() - interval '2 days'
  from generate_series(1, 5)
union all
select 'd1000000-0000-4000-8000-000000000001'::uuid, 'breakdown', 'claude-haiku-4-5',
       'completed', 30000, 3000, 'free', now() - interval '40 days';

select is(public.transfer_subscriptions(
  array['d1000000-0000-4000-8000-000000000001']::uuid[],
  'd1000000-0000-4000-8000-000000000002', 'evt-transfer-1', now() + interval '2 seconds'),
  'transferred', 'a restore moves the purchases to the new install');
select is(public.effective_tier('d1000000-0000-4000-8000-000000000002'), 'pro',
          'the new install is Pro');
select is((select expires_at from public.entitlements
            where user_id = 'd1000000-0000-4000-8000-000000000002'),
          now() + interval '2 months',
          'until the renewal that arrived early');
select is(public.effective_tier('d1000000-0000-4000-8000-000000000001'), 'free',
          'the old install is Free');
select is((select count(*)::integer from public.subscription_transactions
            where user_id = 'd1000000-0000-4000-8000-000000000001'), 0,
          'and keeps none of the purchases');
select is(private.ai_account_cost('d1000000-0000-4000-8000-000000000002', interval '30 days'),
          500000::bigint,
          'the new install carries the old one''s spending');
select throws_ok(
  $$select public.check_and_record_ai_usage(
      'd1000000-0000-4000-8000-000000000002', 'grade', 'claude-opus-5')$$,
  'Q0006', 'ALLOWANCE_WEEKLY',
  'so restoring into a fresh account does not reset the week''s markings');
select is((select count(*)::integer from public.ai_usage
            where user_id = 'd1000000-0000-4000-8000-000000000001'), 1,
          'history older than every limit stays behind');
select is(public.transfer_subscriptions(
  array['d1000000-0000-4000-8000-000000000001']::uuid[],
  'd1000000-0000-4000-8000-000000000002', 'evt-transfer-1', now() + interval '2 seconds'),
  'stale', 'a redelivered transfer does nothing');
select is(public.apply_subscription_state(
  'prod-1', 'd1000000-0000-4000-8000-000000000002', 'prod-1-c',
  'com.felipegutierrez.albus.pro.monthly', 'Production', now(),
  now() + interval '3 months', null, 'evt-prod-3', now() + interval '3 seconds'), 'active_pro',
  'renewals for the new install now apply');
select is(public.transfer_subscriptions(
  array[]::uuid[], 'd1000000-0000-4000-8000-000000000002',
  'evt-transfer-2', now()), 'nothing_to_transfer',
  'a transfer with nothing to move is harmless');
select is(public.effective_tier('d1000000-0000-4000-8000-000000000002'), 'pro',
          'and leaves the plan alone');
select is(public.transfer_subscriptions(
  array['d1000000-0000-4000-8000-000000000002']::uuid[],
  'd1000000-0000-4000-8000-0000000000ff', 'evt-transfer-3', now()), 'invalid',
  'a transfer to an account that does not exist is refused');
select is(public.effective_tier('d1000000-0000-4000-8000-000000000002'), 'pro',
          'and moves nothing');

-- A transfer can also name accounts that never held the purchase. Only the
-- account that gives up a plan gives up its history.
select pg_temp.student('d1000000-0000-4000-8000-000000000006');
select pg_temp.spent('d1000000-0000-4000-8000-000000000005', 'free', 1, 3000);
-- This is a later transfer than evt-transfer-1 (now()+2 seconds).
select is(public.transfer_subscriptions(
  array['d1000000-0000-4000-8000-000000000002',
        'd1000000-0000-4000-8000-000000000005']::uuid[],
  'd1000000-0000-4000-8000-000000000006', 'evt-transfer-4', now() + interval '3 seconds'),
  'transferred', 'a transfer may list an account that never held the purchase');
select is((select count(*)::integer from public.ai_usage
            where user_id = 'd1000000-0000-4000-8000-000000000005'), 1,
          'and that account keeps its own history');
select is((select count(*)::integer from public.ai_usage
            where user_id = 'd1000000-0000-4000-8000-000000000006'), 5,
          'while the history of the plan moves with it');

-- -------------------------------------------------------------------------
-- Who may call what.

select ok(not has_function_privilege('authenticated',
  'public.transfer_subscriptions(uuid[],uuid,text,timestamptz)', 'EXECUTE'),
  'the app cannot move a subscription');
select ok(has_function_privilege('service_role',
  'public.transfer_subscriptions(uuid[],uuid,text,timestamptz)', 'EXECUTE'),
  'the signed webhook can');
select ok(not has_function_privilege('authenticated',
  'public.record_subscription_revenue(text,text,uuid,text,text,text,numeric,numeric,numeric,text,timestamptz)',
  'EXECUTE'),
  'the app cannot invent income');
select ok(has_function_privilege('service_role',
  'public.record_subscription_revenue(text,text,uuid,text,text,text,numeric,numeric,numeric,text,timestamptz)',
  'EXECUTE'),
  'the signed webhook can record it');
select ok(not has_table_privilege('authenticated', 'public.subscription_revenue', 'SELECT'),
          'students cannot read the income ledger');
select ok(not has_table_privilege('authenticated', 'public.subscription_webhook_events', 'INSERT'),
          'students cannot pre-empt a webhook event');

-- -------------------------------------------------------------------------
-- Income. Proceeds are the price less RevenueCat's estimates of tax and
-- commission, both fractions of the gross price.

select is(public.record_subscription_revenue(
  'rev-1', 'INITIAL_PURCHASE', 'd1000000-0000-4000-8000-000000000004', 'p4',
  'com.felipegutierrez.albus.plus.monthly', 'Production', 9.99, 0.1736, 0.15, null, now()),
  'recorded', 'a purchase is recorded');
select is((select net_microusd from public.subscription_revenue where event_id = 'rev-1'),
          6757236::bigint, 'as the price less tax and commission');
select is(public.record_subscription_revenue(
  'rev-1', 'INITIAL_PURCHASE', 'd1000000-0000-4000-8000-000000000004', 'p4',
  'com.felipegutierrez.albus.plus.monthly', 'Production', 9.99, 0.1736, 0.15, null, now()),
  'stale', 'a redelivered purchase is counted once');
select is(public.record_subscription_revenue(
  'rev-trial', 'INITIAL_PURCHASE', 'd1000000-0000-4000-8000-000000000004', 'p5',
  'com.felipegutierrez.albus.plus.monthly', 'Production', 0, 0, 0, null, now()),
  'no_revenue', 'a free trial brings in nothing');
select is(public.record_subscription_revenue(
  'rev-cancel', 'CANCELLATION', 'd1000000-0000-4000-8000-000000000004', 'p4',
  'com.felipegutierrez.albus.plus.monthly', 'Production', 9.99, 0.1736, 0.15, 'UNSUBSCRIBE', now()),
  'no_revenue', 'turning off renewal takes no money back');
select is(public.record_subscription_revenue(
  'rev-refund', 'CANCELLATION', 'd1000000-0000-4000-8000-000000000004', 'p4',
  'com.felipegutierrez.albus.plus.monthly', 'Production', 9.99, 0.1736, 0.15, 'CUSTOMER_SUPPORT', now()),
  'recorded', 'a refund is recorded');
select is((select net_microusd from public.subscription_revenue where event_id = 'rev-refund'),
          -6757236::bigint, 'as money going back out');
select is(public.record_subscription_revenue(
  'rev-refund-negative', 'CANCELLATION', null, 'p6',
  'com.felipegutierrez.albus.plus.monthly', 'Production', -9.99, 0.1736, 0.15, 'CUSTOMER_SUPPORT', now()),
  'recorded', 'a refund reported with a negative price is recorded too');
select is((select net_microusd from public.subscription_revenue where event_id = 'rev-refund-negative'),
          -6757236::bigint, 'with the same sign, whichever way the price was signed');
select is(public.record_subscription_revenue(
  'rev-no-estimates', 'RENEWAL', 'd1000000-0000-4000-8000-000000000004', 'p4',
  'com.felipegutierrez.albus.plus.monthly', 'Production', 10, null, null, null, now()),
  'recorded', 'a renewal without estimates is recorded');
select is((select net_microusd from public.subscription_revenue where event_id = 'rev-no-estimates'),
          4500000::bigint, 'assuming 25% tax and 30% commission, which can only understate it');
select is(public.record_subscription_revenue(
  'rev-absurd', 'RENEWAL', null, 'p7',
  'com.felipegutierrez.albus.pro.annual', 'Production', 1000000000, 0, 0, null, now()),
  'recorded', 'an absurd price is recorded');
select is((select net_microusd from public.subscription_revenue where event_id = 'rev-absurd'),
          1000000000::bigint, 'but capped at US$1,000, so it cannot open the fuse');
select is(public.record_subscription_revenue(
  'rev-bad', 'RENEWAL', null, 'p8',
  'com.felipegutierrez.albus.pro.annual', 'Preview', 9.99, 0, 0, null, now()),
  'invalid', 'an unknown environment is refused');

-- -------------------------------------------------------------------------
-- The fuses. Free keeps US$1; paid starts at US$1 and grows to 25% of the
-- last 30 days of real proceeds, a day's worth at a time.

delete from public.subscription_revenue;

select results_eq($$select * from private.ai_pool_budget('free')$$,
                  $$values (1000000::bigint, 1000000::bigint)$$,
                  'free: US$1 an hour and US$1 a day');
select results_eq($$select * from private.ai_pool_budget('paid')$$,
                  $$values (1000000::bigint, 1000000::bigint)$$,
                  'paid, before any income: the same US$1 floor');

-- US$240 of proceeds: 25% of it over 30 days is US$2 a day.
select pg_temp.proceeds('pool-1', 'Production', 240000000, interval '1 day');
select results_eq($$select * from private.ai_pool_budget('paid')$$,
                  $$values (1000000::bigint, 2000000::bigint)$$,
                  'paid grows to 25% of the last 30 days of proceeds, per day');

-- US$960: US$8 a day, and the hour is a quarter of that.
select pg_temp.proceeds('pool-2', 'Production', 720000000, interval '2 days');
select results_eq($$select * from private.ai_pool_budget('paid')$$,
                  $$values (2000000::bigint, 8000000::bigint)$$,
                  'and the hour grows to a quarter of the day');

select pg_temp.proceeds('pool-3', 'Sandbox', 9000000000, interval '1 hour');
select pg_temp.proceeds('pool-4', 'Production', 9000000000, interval '31 days');
select results_eq($$select * from private.ai_pool_budget('paid')$$,
                  $$values (2000000::bigint, 8000000::bigint)$$,
                  'sandbox money and money older than 30 days do not count');
select results_eq($$select * from private.ai_pool_budget('free')$$,
                  $$values (1000000::bigint, 1000000::bigint)$$,
                  'income never raises the free fuse');

select pg_temp.proceeds('pool-5', 'Production', -5000000000, interval '1 hour');
select results_eq($$select * from private.ai_pool_budget('paid')$$,
                  $$values (1000000::bigint, 1000000::bigint)$$,
                  'refunds cannot push the paid fuse below its floor');

-- -------------------------------------------------------------------------
-- The gate spends from the caller's pool.

delete from public.subscription_revenue;
delete from public.ai_usage;
insert into public.entitlements (user_id, tier, expires_at)
values ('d1000000-0000-4000-8000-000000000004', 'plus', now() + interval '1 month')
on conflict (user_id) do update set tier = excluded.tier, expires_at = excluded.expires_at;

-- Free accounts have spent US$0.98 of real money in the last hour.
select pg_temp.spent('d1000000-0000-4000-8000-000000000009', 'free', 7, 140000);
select throws_ok(
  $$select public.check_and_record_ai_usage(
      'd1000000-0000-4000-8000-000000000005', 'breakdown', 'claude-haiku-4-5')$$,
  'Q0004', 'GLOBAL_CAPACITY_REACHED',
  'a spent free fuse stops free accounts');
select lives_ok(
  $$select public.check_and_record_ai_usage(
      'd1000000-0000-4000-8000-000000000004', 'grade', 'claude-opus-5')$$,
  'but a paying student is still marked');
select is((select budget_pool from public.ai_usage
            where user_id = 'd1000000-0000-4000-8000-000000000004'
              and attempt_state = 'reserved'),
          'paid', 'and the marking is charged to the paid fuse');

-- The call-count fuse is split the same way.
delete from public.ai_usage;
update public.app_config set int_value = 3 where key = 'global_ai_calls_per_hour';
select pg_temp.spent('d1000000-0000-4000-8000-000000000009', 'free', 3, 100);
select throws_ok(
  $$select public.check_and_record_ai_usage(
      'd1000000-0000-4000-8000-000000000005', 'breakdown', 'claude-haiku-4-5')$$,
  'Q0004', 'GLOBAL_CAPACITY_REACHED',
  'free accounts that use up their call count are stopped');
select lives_ok(
  $$select public.check_and_record_ai_usage(
      'd1000000-0000-4000-8000-000000000004', 'breakdown', 'claude-haiku-4-5')$$,
  'without using up the paid call count');
update public.app_config set int_value = 100 where key = 'global_ai_calls_per_hour';

-- And the other way round.
delete from public.ai_usage;
select pg_temp.spent('d1000000-0000-4000-8000-000000000004', 'paid', 7, 140000);
select lives_ok(
  $$select public.check_and_record_ai_usage(
      'd1000000-0000-4000-8000-000000000005', 'breakdown', 'claude-haiku-4-5')$$,
  'paying students'' spending never blocks free accounts');
select is((select budget_pool from public.ai_usage
            where user_id = 'd1000000-0000-4000-8000-000000000005'
              and attempt_state = 'reserved'),
          'free', 'and a free call is charged to the free fuse');
select throws_ok(
  $$select public.check_and_record_ai_usage(
      'd1000000-0000-4000-8000-000000000004', 'grade', 'claude-opus-5')$$,
  'Q0004', 'GLOBAL_CAPACITY_REACHED',
  'the paid fuse stops paid calls at its own limit');

select pg_temp.proceeds('gate-income', 'Production', 960000000, interval '1 day');
select lives_ok(
  $$select public.check_and_record_ai_usage(
      'd1000000-0000-4000-8000-000000000004', 'grade', 'claude-opus-5')$$,
  'income raises the paid fuse, and the same marking fits');

select * from finish();
rollback;
