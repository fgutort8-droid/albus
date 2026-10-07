-- Verify owned/auth erasure and record the audit's retained-data exceptions.
-- Existing billing UUID routes are asserted as retained, not called anonymized.
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;
select no_plan();

create function pg_temp.account_rows(p_relation text,p_user uuid) returns integer
language plpgsql as $$
declare v_count integer;
begin
  execute format('select count(*)::integer from %s t where position($1 in to_jsonb(t)::text)>0',p_relation::regclass)
  into v_count using p_user::text;
  return v_count;
end;
$$;

insert into auth.users(id,instance_id,aud,role,email,encrypted_password,raw_app_meta_data,raw_user_meta_data,created_at,updated_at,is_anonymous)
select ('d0820000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,
 '00000000-0000-0000-0000-000000000000','authenticated','authenticated','erasure-'||g||'@example.invalid','','{}','{}',now(),now(),false
from generate_series(1,2) g;
insert into auth.identities(user_id,provider_id,identity_data,provider,created_at,updated_at)
select u.id,p.provider||'-'||u.id,jsonb_build_object('sub',p.provider||'-'||u.id,'email',u.email),p.provider,now(),now()
from auth.users u cross join (values('apple'),('email')) p(provider)
where u.id in ('d0820000-0000-4000-8000-000000000001','d0820000-0000-4000-8000-000000000002');
insert into auth.sessions(id,user_id,created_at,updated_at)
select ('d0830000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,
 ('d0820000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,now(),now() from generate_series(1,2) g;
insert into auth.refresh_tokens(token,user_id,session_id,created_at,updated_at)
select 'local-erasure-refresh-'||g,('d0820000-0000-4000-8000-'||lpad(g::text,12,'0')),
 ('d0830000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,now(),now() from generate_series(1,2) g;
insert into auth.one_time_tokens(id,user_id,token_type,token_hash,relates_to)
select gen_random_uuid(),u.id,'reauthentication_token','local-erasure-hash-'||u.id,u.email from auth.users u
where u.id in ('d0820000-0000-4000-8000-000000000001','d0820000-0000-4000-8000-000000000002');
insert into auth.mfa_factors(id,user_id,factor_type,status,created_at,updated_at,secret)
select gen_random_uuid(),u.id,'totp','unverified',now(),now(),'local-unused-test-factor' from auth.users u
where u.id in ('d0820000-0000-4000-8000-000000000001','d0820000-0000-4000-8000-000000000002');

insert into public.courses(id,user_id,display_name)
select ('d0840000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,
 ('d0820000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,'Physics' from generate_series(1,2) g;
insert into public.rubrics(id,user_id,name,body)
select ('d0850000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,
 ('d0820000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,'Mark scheme','Personal content' from generate_series(1,2) g;
insert into public.rubric_items(user_id,rubric_id,name,marks)
select user_id,id,'Evidence',10 from public.rubrics where id::text like 'd0850000-%';
insert into public.assignments(id,user_id,course_id,rubric_id,title,deadline,estimated_minutes)
select ('d0860000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,
 ('d0820000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,
 ('d0840000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,
 ('d0850000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,'Personal task',now()+interval '1 week',60 from generate_series(1,2) g;
insert into public.subtasks(id,user_id,assignment_id,title,estimated_minutes)
select ('d0870000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,
 ('d0820000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,
 ('d0860000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,'Personal step',30 from generate_series(1,2) g;
insert into public.plan_sessions(user_id,assignment_id,subtask_id,starts_at,ends_at)
select user_id,assignment_id,id,now(),now()+interval '30 minutes' from public.subtasks where id::text like 'd0870000-%';
insert into public.completion_logs(user_id,subtask_id,task_type,estimated_minutes,actual_minutes)
select user_id,id,'other',30,25 from public.subtasks where id::text like 'd0870000-%';
insert into public.gradings(user_id,assignment_id,rubric_id,model,input_chars,feedback)
select user_id,id,rubric_id,'claude-sonnet-5',300,'Personal feedback' from public.assignments where id::text like 'd0860000-%';
insert into public.entitlements(user_id,tier,expires_at)
select id,'plus',now()+interval '1 month' from auth.users where id::text like 'd0820000-%' on conflict(user_id) do nothing;
insert into public.ai_usage(id,user_id,kind,model,attempt_state,reserved_cost_microusd,actual_cost_microusd)
select ('d0880000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,
 ('d0820000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,'breakdown','claude-haiku-4-5','completed',30000,2500 from generate_series(1,2) g;
insert into public.security_events(user_id,kind,severity)
select id,'full-account-erasure','warn' from auth.users where id::text like 'd0820000-%';
insert into public.identity_links(user_id,kind,hash)
select id,'device',repeat(case when id::text like '%1' then 'b' else 'c' end,64) from auth.users where id::text like 'd0820000-%';
insert into private.api_rate_windows(user_id,window_kind,window_start,hits)
select id,'minute',date_trunc('minute',now()),1 from auth.users where id::text like 'd0820000-%';
insert into public.subscription_transactions(original_transaction_id,user_id,environment,ownership_origin_user_id,ownership_path)
select 'erasure-purchase-'||g,('d0820000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,'Sandbox',
 ('d0820000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,
 array[('d0820000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid] from generate_series(1,2) g;
insert into public.subscription_revenue(event_id,event_type,user_id,original_transaction_id,environment,net_microusd,occurred_at)
select 'erasure-revenue-'||g,'INITIAL_PURCHASE',('d0820000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,
 'erasure-purchase-'||g,'Sandbox',1000000,now() from generate_series(1,2) g;
insert into private.ai_usage_purchases(usage_id,original_transaction_id)
select ('d0880000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,'erasure-purchase-'||g from generate_series(1,2) g on conflict do nothing;
insert into private.financial_inbox(scope,event_id,payload,payload_hash,user_id,state,completed_at)
select 'erasure-audit','erasure-event-'||g,jsonb_build_object('user_id',('d0820000-0000-4000-8000-'||lpad(g::text,12,'0'))),repeat('d',64),
 ('d0820000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,'completed',now() from generate_series(1,2) g;
insert into public.subscription_webhook_events(event_id,event_type) values('erasure-transfer','TRANSFER');
insert into private.subscription_transfers(event_id,event_at,source_ids,destination_id,active_destination_id)
values('erasure-transfer',now(),array['d0820000-0000-4000-8000-000000000001']::uuid[],
 'd0820000-0000-4000-8000-000000000001','d0820000-0000-4000-8000-000000000001');

create temporary table erasure_tables as
select c.oid::regclass::text as relation,n.nspname
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where c.relkind in ('r','p') and (n.nspname in ('public','private') or
 (n.nspname='auth' and c.relname in ('users','identities','sessions','refresh_tokens','one_time_tokens','mfa_factors')));
create temporary table staying_counts as
select relation,pg_temp.account_rows(relation,'d0820000-0000-4000-8000-000000000002') as expected from erasure_tables;

select is((select is_anonymous from auth.users where id='d0820000-0000-4000-8000-000000000001'),false,'fixture is a real non-anonymous account');
select is((select count(*)::integer from auth.identities where user_id='d0820000-0000-4000-8000-000000000001'),2,'fixture has Apple and email identities');
set local role authenticated;
select set_config('request.jwt.claim.sub','d0820000-0000-4000-8000-000000000001',true);
select lives_ok($$select public.delete_my_account()$$,'real account deletes through the existing caller-scoped RPC');
reset role;
select set_config('request.jwt.claim.sub','',true);
select set_config('request.jwt.claims','',true);

-- All 31 application tables are inspected, including empty reference tables.
-- Retained UUID routes are explicit exceptions, listed in the audit.
select is(pg_temp.account_rows(relation,'d0820000-0000-4000-8000-000000000001'),0,'erased every account reference in '||relation)
from erasure_tables where relation not in ('identity_links','public.identity_links','subscription_transactions','public.subscription_transactions','private.financial_inbox','private.subscription_transfers') order by relation;
select is(pg_temp.account_rows(relation,'d0820000-0000-4000-8000-000000000002'),expected,'other account unchanged in '||relation) from staying_counts order by relation;
select is((select count(*)::integer from public.ai_usage where id='d0880000-0000-4000-8000-000000000001' and user_id is null),1,'AI cost row survives without user_id');
select is((select count(*)::integer from public.security_events where kind='full-account-erasure' and user_id is null),1,'security warning survives without user_id');
select is((select count(*)::integer from public.identity_links where user_id='d0820000-0000-4000-8000-000000000001'),1,'documented pseudonymous fraud observation survives for its retention window');
select is((select count(*)::integer from public.subscription_transactions where original_transaction_id='erasure-purchase-1' and user_id is null),1,'purchase user_id is detached');
select is((select count(*)::integer from public.subscription_revenue where event_id='erasure-revenue-1' and user_id is null),1,'revenue survives without user_id');
select is((select count(*)::integer from private.subscription_transfers where event_id='erasure-transfer' and active_destination_id is null),1,'active transfer destination is detached');
select is(pg_temp.account_rows('private.financial_audit','d0820000-0000-4000-8000-000000000001'),0,'immutable financial audit contains no account UUID');
select ok(exists(select 1 from private.financial_audit where resource_hash=encode(extensions.digest('d0820000-0000-4000-8000-000000000001','sha256'),'hex')),'immutable financial evidence survives keyed only by a hash');

-- Retained for now and disclosed in the privacy policy since 7 October 2026.
-- Replacing them with a hash is an open billing change; if it lands, these
-- assertions change with it.
select is(pg_temp.account_rows('private.financial_inbox','d0820000-0000-4000-8000-000000000001'),1,'RETAINED, disclosed: completed payment payload and user_id still name the deleted account');
select is(pg_temp.account_rows('public.subscription_transactions','d0820000-0000-4000-8000-000000000001'),1,'RETAINED, disclosed: purchase ownership origin/path retain the deleted UUID');
select is(pg_temp.account_rows('private.subscription_transfers','d0820000-0000-4000-8000-000000000001'),1,'RETAINED, disclosed: transfer source/destination retain the deleted UUID');

insert into auth.users(id,instance_id,aud,role,encrypted_password,raw_app_meta_data,raw_user_meta_data,created_at,updated_at,last_sign_in_at,is_anonymous)
select ('d0890000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,
 '00000000-0000-0000-0000-000000000000','authenticated','authenticated','','{}','{}',now()-interval '3 years',now()-interval '3 years',now()-interval '3 years',g=2
from generate_series(1,2) g;
select lives_ok($$select public.reap_abandoned_anonymous_users(30)$$,'scheduled cleanup runs');
select is((select count(*)::integer from auth.users where id='d0890000-0000-4000-8000-000000000001'),1,'old empty non-anonymous account is spared');
select is((select count(*)::integer from auth.users where id='d0890000-0000-4000-8000-000000000002'),0,'old empty anonymous account is reaped');
select * from finish();
rollback;
