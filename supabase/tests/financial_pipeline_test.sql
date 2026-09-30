begin;
create extension if not exists pgtap with schema extensions;
set local search_path=public,extensions;
select plan(37);
insert into auth.users(id,instance_id,aud,role,encrypted_password,raw_app_meta_data,raw_user_meta_data,created_at,updated_at,is_anonymous)
values('f9000000-0000-4000-8000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated','','{}','{}',now(),now(),false);
create function pg_temp.event_payload(p_id text,p_product text default 'com.felipegutierrez.albus.plus.monthly') returns jsonb
language sql as $$ select jsonb_build_object('operation','subscription','subscription',jsonb_build_object(
'p_original_transaction_id','financial-test-transaction','p_user_id','f9000000-0000-4000-8000-000000000001',
'p_latest_transaction_id','financial-test-latest','p_product_id',p_product,'p_environment','Production',
'p_purchase_date',now(),'p_expires_at',now()+interval '1 month','p_revoked_at',null,
'p_event_id',p_id,'p_event_at',now(),'p_store','APP_STORE','p_app_id','financial-test-app'),
'revenue',jsonb_build_object('p_event_id',p_id,'p_event_type','INITIAL_PURCHASE',
'p_user_id','f9000000-0000-4000-8000-000000000001','p_original_transaction_id','financial-test-transaction',
'p_product_id',p_product,'p_environment','Production','p_price_usd',10,'p_tax_fraction',0,'p_commission_fraction',0.3,
'p_cancel_reason',null,'p_occurred_at',now())); $$;

-- Who may touch the queue and the audit log.
select ok(not has_table_privilege('service_role','private.financial_audit','DELETE'),'runtime cannot delete audit');
select ok(not has_table_privilege('authenticated','private.financial_inbox','SELECT'),'clients cannot read events');
select ok(not has_function_privilege('authenticated','public.process_financial_event(uuid)','EXECUTE'),'clients cannot process events');
select ok(not has_function_privilege('anon','public.enqueue_revenuecat_event(text,text,jsonb)','EXECUTE'),'anonymous cannot enqueue');
select ok(not has_function_privilege('authenticated','public.enqueue_revenuecat_event(text,text,jsonb)','EXECUTE'),'signed-in clients cannot enqueue');
select ok(not has_function_privilege('authenticated','public.drain_financial_events(integer)','EXECUTE'),'clients cannot run the retry job');

-- Accepted once, applied once.
create temp table ids(name text,id uuid);
insert into ids values('valid',public.enqueue_revenuecat_event('test-app','financial-valid',pg_temp.event_payload('financial-valid')));
select is(public.enqueue_revenuecat_event('test-app','financial-valid',pg_temp.event_payload('financial-valid')),
(select id from ids where name='valid'),'duplicate accepted identity is stable');
select throws_ok($$select public.enqueue_revenuecat_event('test-app','financial-valid',pg_temp.event_payload('financial-valid','different'))$$,
'22023','FINANCIAL_EVENT_ID_REUSED','changed inputs cannot reuse event id');
select is((select count(*)::integer from private.financial_inbox where event_id='financial-valid'),1,'one durable inbox row');
select is(public.process_financial_event((select id from ids where name='valid')),'active_plus','process applies entitlement');
select is(public.effective_tier('f9000000-0000-4000-8000-000000000001'),'plus','verified owner receives plan');
select is((select count(*)::integer from public.subscription_revenue where event_id='financial-valid'),1,'revenue recorded once');
select is(public.process_financial_event((select id from ids where name='valid')),'active_plus','retry returns original result');
select is((select attempts from private.financial_inbox where event_id='financial-valid'),1,'completed replay performs no work');
select ok(exists(select from private.financial_audit where event_ref=(select id from ids where name='valid') and action='entitlements.update')
 or exists(select from private.financial_audit where event_ref=(select id from ids where name='valid') and action='entitlements.insert'),
'entitlement mutation has attributable audit evidence');
select throws_ok($$update private.financial_audit set reason='altered'$$,'42501','IMMUTABLE_FINANCIAL_AUDIT','audit rewrite denied even to owner');
select throws_ok($$delete from private.financial_audit$$,'42501','IMMUTABLE_FINANCIAL_AUDIT','audit deletion denied');

-- A failure changes nothing and stays queued.
insert into ids values('unknown',public.enqueue_revenuecat_event('test-app','financial-unknown',pg_temp.event_payload('financial-unknown','unmapped')));
select is(public.process_financial_event((select id from ids where name='unknown')),'retry','unknown mapping persists retry');
select is((select state from private.financial_inbox where event_id='financial-unknown'),'retry','failed event remains durable');
select is((select count(*)::integer from public.subscription_revenue where event_id='financial-unknown'),0,'failure rolls back revenue with entitlement');
select is((select product_id from public.subscription_transactions where original_transaction_id='financial-test-transaction'),
'com.felipegutierrez.albus.plus.monthly','failure preserves previous subscription');

-- The retry job, dead letters and requeue.
update private.financial_inbox set available_at=now() where event_id='financial-unknown';
select ok(public.drain_financial_events(25)>=1,'retry job processes ready events');
select is((select attempts from private.financial_inbox where event_id='financial-unknown'),2,'retry job made one more attempt');
update private.financial_inbox set attempts=9,available_at=now() where event_id='financial-unknown';
select is(public.process_financial_event((select id from ids where name='unknown')),'retry','tenth failure still answers retry');
select is((select state from private.financial_inbox where event_id='financial-unknown'),'dead','tenth failure becomes a dead letter');
select is(public.process_financial_event((select id from ids where name='unknown')),'dead','dead letters are not retried automatically');
select throws_ok($$select public.requeue_financial_event((select id from ids where name='unknown'),'x')$$,
'P0001','TICKET_REQUIRED','requeue needs a ticket reference');
select lives_ok($$select public.requeue_financial_event((select id from ids where name='unknown'),'INC-1')$$,'owner can requeue a dead letter');
select is((select state||':'||attempts from private.financial_inbox where event_id='financial-unknown'),'retry:0','requeued event is ready to retry');
select ok(not has_function_privilege('service_role','public.requeue_financial_event(uuid,text)','EXECUTE'),'runtime cannot bypass dead-letter review');

-- Retention erases old payloads but still refuses replays.
update private.financial_inbox set completed_at=now()-interval '31 days' where event_id='financial-valid';
select ok(public.prune_financial_inbox()>=1,'old completed payloads are erased');
select is((select payload from private.financial_inbox where event_id='financial-valid'),'{}'::jsonb,'erased event keeps only identity, hash and result');
select is(public.enqueue_revenuecat_event('test-app','financial-valid',pg_temp.event_payload('financial-valid')),
(select id from ids where name='valid'),'erased event still blocks a replay');

-- Truncation and schedules.
select throws_ok($$truncate private.financial_audit cascade$$,'42501','IMMUTABLE_FINANCIAL_AUDIT','truncation cannot erase audit');
select ok(not has_table_privilege('service_role','public.entitlements','TRUNCATE'),'runtime cannot silently truncate entitlements');
select is((select count(*)::integer from cron.job where jobname in ('albus-financial-drain','albus-financial-payload-retention') and active),2,
'retry job and payload retention are scheduled without credentials');
select is((select schedule from cron.job where jobname='albus-financial-drain'),'*/5 * * * *','retry job runs every five minutes');
select * from finish();
rollback;
