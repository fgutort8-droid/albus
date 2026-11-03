begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;
select no_plan();

insert into auth.users(id,instance_id,aud,role,encrypted_password,raw_app_meta_data,raw_user_meta_data,created_at,updated_at,is_anonymous)
select ('d0800000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,
 '00000000-0000-0000-0000-000000000000','authenticated','authenticated','','{}','{}',now(),now(),false
from generate_series(1,2) g;
insert into public.assignments(id,user_id,title,deadline,estimated_minutes,status)
select ('d0810000-0000-4000-8000-'||lpad(g::text,12,'0'))::uuid,
 'd0800000-0000-4000-8000-000000000001','Task '||g,now()+interval '1 week',60,
 case when g<=5 then 'active' when g<=8 then 'completed' else 'archived' end
from generate_series(1,9) g;
insert into public.assignments(id,user_id,title,deadline,estimated_minutes)
values('d0810000-0000-4000-8000-000000000010','d0800000-0000-4000-8000-000000000002','Other student',now()+interval '1 week',60);
insert into public.subtasks(user_id,assignment_id,title,estimated_minutes)
values('d0800000-0000-4000-8000-000000000001','d0810000-0000-4000-8000-000000000002','Keep this step',30);

insert into public.gradings(user_id,assignment_id,model,input_chars,feedback)
values('d0800000-0000-4000-8000-000000000001','d0810000-0000-4000-8000-000000000002','claude-sonnet-5',300,'Keep this grading');

select ok(not has_function_privilege('anon','public.sync_my_assignments(uuid[],uuid[])','execute'),'anon cannot sync');
select ok(not has_function_privilege('anon','public.release_my_other_assignments(uuid[])','execute'),'anon cannot release');
select ok(has_function_privilege('authenticated','public.sync_my_assignments(uuid[],uuid[])','execute'),'authenticated can sync');
select ok(has_function_privilege('authenticated','public.release_my_other_assignments(uuid[])','execute'),'authenticated can release');
select is(pg_get_function_identity_arguments('public.sync_my_assignments(uuid[],uuid[])'::regprocedure),'p_finished uuid[], p_open uuid[]','sync arguments exact');
select is(pg_get_function_identity_arguments('public.release_my_other_assignments(uuid[])'::regprocedure),'p_keep uuid[]','release arguments exact');
select ok(prosecdef and 'search_path=""'=any(proconfig),'sync definer with empty path') from pg_proc where oid='public.sync_my_assignments(uuid[],uuid[])'::regprocedure;
select ok(prosecdef and 'search_path=""'=any(proconfig),'release definer with empty path') from pg_proc where oid='public.release_my_other_assignments(uuid[])'::regprocedure;
select set_config('request.jwt.claim.sub','',true);
select throws_ok($$select public.sync_my_assignments(null,null)$$,'28000','NOT_SIGNED_IN','sync requires a caller');
select throws_ok($$select public.release_my_other_assignments(null)$$,'28000','NOT_SIGNED_IN','release requires a caller');

set local role authenticated;
select set_config('request.jwt.claim.sub','d0800000-0000-4000-8000-000000000001',true);
select is(public.sync_my_assignments(null,array['d0810000-0000-4000-8000-000000000006','d0810000-0000-4000-8000-000000000007']::uuid[]),0,'cap refuses each reopen without failing call');
select is((select status from public.assignments where id='d0810000-0000-4000-8000-000000000006'),'completed','refused row stays completed');
select is(public.sync_my_assignments(array['d0810000-0000-4000-8000-000000000001']::uuid[],array['d0810000-0000-4000-8000-000000000006']::uuid[]),2,'finish before reopen swaps places under cap');
select is(public.sync_my_assignments(array['d0810000-0000-4000-8000-000000000001']::uuid[],array['d0810000-0000-4000-8000-000000000006']::uuid[]),0,'identical sync is harmless');
select is(public.sync_my_assignments(array['d0810000-0000-4000-8000-000000000002']::uuid[],array['d0810000-0000-4000-8000-000000000002']::uuid[]),0,'conflicting id stays alone');
select is(public.sync_my_assignments(array['d0810000-0000-4000-8000-000000000010']::uuid[],array['d0810000-0000-4000-8000-000000000009','d0810000-0000-4000-8000-000000000010']::uuid[]),0,'foreign and archived rows never change');
select throws_ok($$select public.sync_my_assignments(array_fill(gen_random_uuid(),array[501]),null)$$,'22023','TOO_MANY_IDS','finished list bounded');
select throws_ok($$select public.sync_my_assignments(null,array_fill(gen_random_uuid(),array[501]))$$,'22023','TOO_MANY_IDS','open list bounded');
select throws_ok($$select public.release_my_other_assignments(array_fill(gen_random_uuid(),array[501]))$$,'22023','TOO_MANY_IDS','keep list bounded');
select is(public.sync_my_assignments(array['d0810000-0000-4000-8000-000000000006',null]::uuid[],null),1,'finish frees one active place; null elements ignored');
reset role;
select lives_ok($$insert into public.assignments(user_id,title,deadline,estimated_minutes) values('d0800000-0000-4000-8000-000000000001','New normal task',now()+interval '1 week',60)$$,'normal insert can use the freed place');
set local role authenticated;
select is(public.release_my_other_assignments(array['d0810000-0000-4000-8000-000000000003',null]::uuid[]),4,'release archives only other active rows');
select is(public.release_my_other_assignments(array['d0810000-0000-4000-8000-000000000003']::uuid[]),0,'repeated release returns zero');
select is((select count(*)::integer from public.assignments where status='active'),1,'active cap count equals kept count');
select is((select status from public.assignments where id='d0810000-0000-4000-8000-000000000003'),'active','kept row stays active');
select is((select status from public.assignments where id='d0810000-0000-4000-8000-000000000006'),'completed','release leaves completed rows alone');
select is((select count(*)::integer from public.subtasks where assignment_id='d0810000-0000-4000-8000-000000000002'),1,'archiving preserves subtasks');
select is((select count(*)::integer from public.gradings where assignment_id='d0810000-0000-4000-8000-000000000002'),1,'archiving preserves gradings');
select is(public.release_my_other_assignments('{}'::uuid[]),1,'empty list frees every active place');
select is(public.release_my_other_assignments(null),0,'null list is empty and repeat is harmless');
reset role;
insert into public.assignments(user_id,title,deadline,estimated_minutes)
values('d0800000-0000-4000-8000-000000000001','One more local task',now()+interval '1 week',60);
set local role authenticated;
select is(public.release_my_other_assignments(null),1,'null keep list releases an actual active task');
select is(public.sync_my_assignments(null,null),0,'null sync lists are empty');
-- No open task now, so the cap has room: only the archived rule keeps these out.
select is(public.sync_my_assignments(null,array['d0810000-0000-4000-8000-000000000009','d0810000-0000-4000-8000-000000000002','d0810000-0000-4000-8000-000000000003']::uuid[]),0,'with room under the cap, freed tasks still never reopen');
select is((select count(*)::integer from public.assignments where id in ('d0810000-0000-4000-8000-000000000009','d0810000-0000-4000-8000-000000000002','d0810000-0000-4000-8000-000000000003') and status='archived'),3,'freed tasks stay archived');
reset role;
select is((select status from public.assignments where id='d0810000-0000-4000-8000-000000000010'),'active','other account survives sync and release');
select is((select status from public.assignments where id='d0810000-0000-4000-8000-000000000009'),'archived','archived row never returns');
select * from finish();
rollback;
