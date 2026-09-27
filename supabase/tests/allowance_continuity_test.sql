begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public;
select no_plan();
insert into auth.users(id,instance_id,aud,role,created_at,updated_at,is_anonymous)
select ('a9600000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',now(),now(),true from generate_series(1,4) i;
select public.apply_verified_subscription_state('continuity-a','a9600000-0000-4000-8000-000000000001','tx-a','com.felipegutierrez.albus.pro.monthly','Production',now(),now()+interval '1 month',null,'continuity-buy-a',now()-interval '3 days','APP_STORE','unit-app');
select public.apply_verified_subscription_state('continuity-b','a9600000-0000-4000-8000-000000000001','tx-b','com.felipegutierrez.albus.pro.monthly','Production',now(),now()+interval '1 month',null,'continuity-buy-b',now()-interval '3 days','APP_STORE','other-app');
insert into public.ai_usage(user_id,kind,model,attempt_state,reserved_cost_microusd,actual_cost_microusd,budget_pool,created_at)
select 'a9600000-0000-4000-8000-000000000001','grade','claude-opus-5','completed',450000,100000,'paid',now()-interval '10 minutes' from generate_series(1,5);
select is(public.ai_spend_count('a9600000-0000-4000-8000-000000000001','grade',interval '7 days'),5,'initial account has five delivered results');
select public.transfer_verified_subscriptions(array['a9600000-0000-4000-8000-000000000001']::uuid[],'a9600000-0000-4000-8000-000000000002','continuity-transfer',now()-interval '1 minute',array['unit-app']);
select is(public.ai_spend_count('a9600000-0000-4000-8000-000000000001','grade',interval '7 days'),5,'retained purchase keeps source allowance after scoped transfer');
select is(public.ai_spend_count('a9600000-0000-4000-8000-000000000002','grade',interval '7 days'),5,'destination inherits allowance');
select is(private.ai_attempt_count('a9600000-0000-4000-8000-000000000001','grade',interval '1 hour'),5,'retained purchase keeps attempts');
select is(private.ai_account_cost('a9600000-0000-4000-8000-000000000001',interval '30 days'),500000::bigint,'retained purchase keeps account cost');
select is(public.ai_window_resets_at('a9600000-0000-4000-8000-000000000001','grade',interval '7 days'),now()-interval '10 minutes'+interval '7 days','original reset time survives scoped transfer');
set local role authenticated;
select set_config('request.jwt.claim.sub','a9600000-0000-4000-8000-000000000002',true);
select public.delete_my_account();
reset role;
select public.apply_verified_subscription_state('continuity-a','a9600000-0000-4000-8000-000000000003','tx-restore','com.felipegutierrez.albus.pro.monthly','Production',now(),now()+interval '1 month',null,'continuity-restore',now(),'APP_STORE','unit-app');
select is(public.ai_spend_count('a9600000-0000-4000-8000-000000000003','grade',interval '7 days'),5,'restored purchase retains allowance after account deletion');
select is(private.ai_account_cost('a9600000-0000-4000-8000-000000000003',interval '30 days'),500000::bigint,'restore retains billed cost');
select is(private.ai_attempt_count('a9600000-0000-4000-8000-000000000003','grade',interval '1 hour'),5,'restore retains attempts');
select is(public.ai_spend_count('a9600000-0000-4000-8000-000000000004','grade',interval '7 days'),0,'unrelated account has no inherited usage');
select is((select sum(actual_cost_microusd) from public.ai_usage where model='claude-opus-5' and created_at=now()-interval '10 minutes'),500000::bigint,'global money is never duplicated');
-- Replayed receipts cannot undo the newer post-deletion restore.
select public.apply_verified_subscription_state('continuity-a','a9600000-0000-4000-8000-000000000001','tx-old',
 'com.felipegutierrez.albus.pro.monthly','Production',now(),now()+interval '1 month',null,'continuity-old-replay',now()-interval '2 days','APP_STORE','unit-app');
select is((select user_id from public.subscription_transactions where original_transaction_id='continuity-a'),
 'a9600000-0000-4000-8000-000000000003'::uuid,'old receipt does not replace a confirmed restore');
select public.apply_verified_subscription_state('continuity-c','a9600000-0000-4000-8000-000000000003','tx-c',
 'com.felipegutierrez.albus.pro.monthly','Production',now(),now()+interval '1 month',null,'continuity-buy-c',now(),'APP_STORE','other-app');
select public.transfer_verified_subscriptions(array['a9600000-0000-4000-8000-000000000003']::uuid[],
 'a9600000-0000-4000-8000-000000000001','continuity-return',now()+interval '1 minute',array['unit-app']);
select is(public.ai_spend_count('a9600000-0000-4000-8000-000000000001','grade',interval '7 days'),5,
 'two purchases linking the same usage count it only once');
select is(private.ai_account_cost('a9600000-0000-4000-8000-000000000001',interval '30 days'),500000::bigint,
 'two purchase links never double-count money');
select is(public.ai_spend_count('a9600000-0000-4000-8000-000000000003','grade',interval '7 days'),5,
 'new purchase inherits restored historical allowance before an older purchase leaves');

select public.prune_security_data(30,30);
select is(public.ai_spend_count('a9600000-0000-4000-8000-000000000001','grade',interval '7 days'),5,
 'daily pruning preserves active allowance links');
insert into public.ai_usage(user_id,kind,model,attempt_state,reserved_cost_microusd,actual_cost_microusd,budget_pool,created_at)
 values('a9600000-0000-4000-8000-000000000001','grade','claude-opus-5','completed',450000,100000,'paid',now()-interval '31 days');
select is((select count(*) from private.ai_usage_purchases l join public.ai_usage u on u.id=l.usage_id
 where u.created_at <= now()-interval '30 days'),0::bigint,'expired usage acquires no new purchase links');
select ok((select relrowsecurity from pg_class where oid='private.ai_usage_purchases'::regclass),'usage links have RLS');
select ok(not has_table_privilege('authenticated','private.ai_usage_purchases','select,insert,update,delete'),'clients cannot access usage links');
select ok(not has_function_privilege('authenticated','private.link_purchase_usage(uuid)','execute'),'clients cannot change purchase usage');
select * from finish();
rollback;
