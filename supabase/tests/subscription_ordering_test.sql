begin;
create extension if not exists pgtap with schema extensions;
set local search_path=extensions,public;
select no_plan();
insert into auth.users(id,instance_id,aud,role,created_at,updated_at,is_anonymous)
select ('a9500000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',now(),now(),true from generate_series(1,15) i;
select public.apply_subscription_state('ordering-main','a9500000-0000-4000-8000-000000000001','ordering-tx','com.felipegutierrez.albus.pro.monthly','Production',now(),now()+interval '1 month',null,'ordering-purchase',now());
select is(public.transfer_subscriptions(array['a9500000-0000-4000-8000-000000000001']::uuid[],'a9500000-0000-4000-8000-000000000002','ordering-new',now()+interval '20 seconds'),'transferred','newer transfer applies');
select public.transfer_subscriptions(array['a9500000-0000-4000-8000-000000000002']::uuid[],'a9500000-0000-4000-8000-000000000001','ordering-old',now()+interval '10 seconds');
select is((select user_id from public.subscription_transactions where original_transaction_id='ordering-main'),'a9500000-0000-4000-8000-000000000002'::uuid,'older reversed event does not roll ownership back');
select is(public.transfer_subscriptions(array['a9500000-0000-4000-8000-000000000001']::uuid[],'a9500000-0000-4000-8000-000000000002','ordering-new',now()+interval '20 seconds'),'stale','duplicate delivery has no second effect');
-- A chain delivered in reverse order must converge to its chronological owner.
select public.transfer_subscriptions(array['a9500000-0000-4000-8000-000000000003']::uuid[],'a9500000-0000-4000-8000-000000000004','ordering-hop2',now()+interval '40 seconds');
select public.transfer_subscriptions(array['a9500000-0000-4000-8000-000000000002']::uuid[],'a9500000-0000-4000-8000-000000000003','ordering-hop1',now()+interval '30 seconds');
select is((select user_id from public.subscription_transactions where original_transaction_id='ordering-main'),'a9500000-0000-4000-8000-000000000004'::uuid,'reverse-delivered chain converges');
-- A later fresh purchase by a former owner does not travel through old transfers.
select public.apply_subscription_state('ordering-fresh','a9500000-0000-4000-8000-000000000001','ordering-fresh-tx','com.felipegutierrez.albus.pro.monthly','Production',now()+interval '50 seconds',now()+interval '1 month',null,'ordering-fresh-buy',now()+interval '50 seconds');
select is((select user_id from public.subscription_transactions where original_transaction_id='ordering-fresh'),'a9500000-0000-4000-8000-000000000001'::uuid,'fresh purchase stays with the purchasing account');
-- A renewal timestamp must not become an ownership ordering watermark.
select public.apply_subscription_state('ordering-main','a9500000-0000-4000-8000-000000000004','ordering-renew-tx','com.felipegutierrez.albus.pro.monthly','Production',now()+interval '100 seconds',now()+interval '1 month',null,'ordering-renew',now()+interval '100 seconds');
select public.transfer_subscriptions(array['a9500000-0000-4000-8000-000000000004']::uuid[],'a9500000-0000-4000-8000-000000000005','ordering-hop3',now()+interval '60 seconds');
select is((select user_id from public.subscription_transactions where original_transaction_id='ordering-main'),'a9500000-0000-4000-8000-000000000005'::uuid,'transfer ordering is independent of billing renewal ordering');

-- Omitted metadata can move only explicitly verified Apple purchases.
select is(public.transfer_verified_subscriptions(array['a9500000-0000-4000-8000-000000000006']::uuid[],
  'a9500000-0000-4000-8000-000000000007','ordering-pending',now()+interval '10 seconds',array['unit-app']),
  'nothing_to_transfer','early transfer remains pending until its purchase arrives');
select public.apply_verified_subscription_state('ordering-verified','a9500000-0000-4000-8000-000000000006','verified-tx',
  'com.felipegutierrez.albus.pro.monthly','Production',now(),now()+interval '1 month',null,'verified-buy',now(),'APP_STORE','unit-app');
select is((select user_id from public.subscription_transactions where original_transaction_id='ordering-verified'),
  'a9500000-0000-4000-8000-000000000007'::uuid,'late purchase resolves through pending transfer');
select public.apply_subscription_state('ordering-unverified','a9500000-0000-4000-8000-000000000006','unverified-tx',
  'com.felipegutierrez.albus.pro.monthly','Production',now(),now()+interval '1 month',null,'unverified-buy',now());
select is((select user_id from public.subscription_transactions where original_transaction_id='ordering-unverified'),
  'a9500000-0000-4000-8000-000000000006'::uuid,'unknown provenance does not satisfy omitted metadata');
select public.apply_verified_subscription_state('ordering-other-app','a9500000-0000-4000-8000-000000000006','other-tx',
  'com.felipegutierrez.albus.pro.monthly','Production',now(),now()+interval '1 month',null,'other-buy',now(),'APP_STORE','other-app');
select is((select user_id from public.subscription_transactions where original_transaction_id='ordering-other-app'),
  'a9500000-0000-4000-8000-000000000006'::uuid,'a stored different app remains outside the transfer scope');
select is(public.apply_verified_subscription_state('ordering-test-store','a9500000-0000-4000-8000-000000000006','test-tx',
  'com.felipegutierrez.albus.pro.monthly','Production',now(),now()+interval '1 month',null,'test-buy',now(),'TEST_STORE','unit-app'),
  'invalid','Test Store cannot establish verified purchase provenance');
select is(public.transfer_verified_subscriptions(array['a9500000-0000-4000-8000-000000000007']::uuid[],
  'a9500000-0000-4000-8000-000000000008','ordering-bad-store',now()+interval '20 seconds',array['unit-app'],null,'TEST_STORE'),
  'invalid','explicit non-Apple transfer metadata is rejected');
select is(public.transfer_verified_subscriptions(array['a9500000-0000-4000-8000-000000000007']::uuid[],
  'a9500000-0000-4000-8000-000000000008','ordering-bad-app',now()+interval '20 seconds',array['unit-app'],'other-app'),
  'invalid','explicit other-app transfer metadata is rejected');
select is(public.transfer_verified_subscriptions(array['a9500000-0000-4000-8000-000000000007']::uuid[],
  'a9500000-0000-4000-8000-000000000008','ordering-no-apps',now()+interval '20 seconds','{}'::text[]),
  'invalid','empty configured app scope is rejected');
select ok((select relrowsecurity from pg_class where oid='private.subscription_transfers'::regclass),'transfer ledger has RLS');
select ok(not has_table_privilege('authenticated','private.subscription_transfers','select,insert,update,delete'),'clients cannot access the transfer ledger');
select ok(not has_function_privilege('authenticated','public.transfer_verified_subscriptions(uuid[],uuid,text,timestamptz,text[],text,text,text)','execute'),'clients cannot execute verified transfers');
select ok(has_function_privilege('service_role','public.transfer_verified_subscriptions(uuid[],uuid,text,timestamptz,text[],text,text,text)','execute'),'server can execute verified transfers');

select is(public.apply_verified_subscription_state('ordering-unverified','a9500000-0000-4000-8000-000000000006','unverified-tx',
  'com.felipegutierrez.albus.pro.monthly','Production',now(),now()+interval '1 month',null,'unverified-buy',now(),'APP_STORE','unit-app'),
  'stale','verified retry does not reapply existing purchase facts');
select is((select user_id from public.subscription_transactions where original_transaction_id='ordering-unverified'),
  'a9500000-0000-4000-8000-000000000007'::uuid,'verified retry resolves a pending transfer during handler upgrade');
select is(public.apply_verified_subscription_state('ordering-verified','a9500000-0000-4000-8000-000000000007','changed-env',
  'com.felipegutierrez.albus.pro.monthly','Sandbox',now(),now()+interval '1 month',null,'changed-env-event',now()+interval '30 seconds','APP_STORE','unit-app'),
  'conflict','verified store environment cannot be rebound');

-- Delivery order of the first purchase and a renewal cannot define ownership.
select public.apply_verified_subscription_state('ordering-late-first','a9500000-0000-4000-8000-000000000008','late-renewal',
 'com.felipegutierrez.albus.pro.monthly','Production',now(),now()+interval '1 month',null,'late-renewal-event',now()+interval '30 seconds','APP_STORE','unit-app');
select public.transfer_verified_subscriptions(array['a9500000-0000-4000-8000-000000000008']::uuid[],
 'a9500000-0000-4000-8000-000000000009','late-first-transfer',now()+interval '20 seconds',array['unit-app']);
select public.apply_verified_subscription_state('ordering-late-first','a9500000-0000-4000-8000-000000000008','late-initial',
 'com.felipegutierrez.albus.pro.monthly','Production',now(),now()+interval '1 month',null,'late-initial-event',now()+interval '10 seconds','APP_STORE','unit-app');
select is((select user_id from public.subscription_transactions where original_transaction_id='ordering-late-first'),
 'a9500000-0000-4000-8000-000000000009'::uuid,'late first purchase resolves ownership without reverting newer billing facts');
select is((select latest_transaction_id from public.subscription_transactions where original_transaction_id='ordering-late-first'),
 'late-renewal','older purchase does not overwrite renewal facts');


select public.apply_verified_subscription_state('ordering-deleted-hop','a9500000-0000-4000-8000-000000000010','hop-buy',
 'com.felipegutierrez.albus.pro.monthly','Production',now(),now()+interval '1 month',null,'hop-buy-event',now(),'APP_STORE','unit-app');
select public.transfer_verified_subscriptions(array['a9500000-0000-4000-8000-000000000011']::uuid[],
 'a9500000-0000-4000-8000-000000000012','hop-second',now()+interval '20 seconds',array['unit-app']);
delete from auth.users where id='a9500000-0000-4000-8000-000000000011';
select public.transfer_verified_subscriptions(array['a9500000-0000-4000-8000-000000000010']::uuid[],
 'a9500000-0000-4000-8000-000000000011','hop-first',now()+interval '10 seconds',array['unit-app']);
select is((select user_id from public.subscription_transactions where original_transaction_id='ordering-deleted-hop'),
 'a9500000-0000-4000-8000-000000000012'::uuid,'historical deleted intermediate does not interrupt the route to a live owner');
select public.apply_verified_subscription_state('ordering-late-restore','a9500000-0000-4000-8000-000000000013','restore-buy',
 'com.felipegutierrez.albus.pro.monthly','Production',now(),now()+interval '1 month',null,'restore-buy-event',now(),'APP_STORE','unit-app');
delete from auth.users where id='a9500000-0000-4000-8000-000000000013';
select public.apply_verified_subscription_state('ordering-late-restore',null,'ownerless-renewal',
 'com.felipegutierrez.albus.pro.monthly','Production',now(),now()+interval '2 months',null,'ownerless-renewal-event',now()+interval '30 seconds','APP_STORE','unit-app');
select public.apply_verified_subscription_state('ordering-late-restore','a9500000-0000-4000-8000-000000000014','older-restore',
 'com.felipegutierrez.albus.pro.monthly','Production',now(),now()+interval '1 month',null,'older-restore-event',now()+interval '20 seconds','APP_STORE','unit-app');
select is((select user_id from public.subscription_transactions where original_transaction_id='ordering-late-restore'),
 'a9500000-0000-4000-8000-000000000014'::uuid,'restore ownership can advance independently of newer billing facts');
select is((select latest_transaction_id from public.subscription_transactions where original_transaction_id='ordering-late-restore'),
 'ownerless-renewal','restoring ownership preserves the later billing event');

select * from finish();
rollback;
