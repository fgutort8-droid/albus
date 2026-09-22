-- Deleting an account: what goes, what stays, and who may ask.
--
-- The line this file defends is the one that makes anonymous accounts safe to
-- give away for free. A student must be able to erase everything they wrote;
-- the hashed device and network observations that stop one person farming
-- endless free accounts must survive them, and so must the rows the money is
-- reconciled from. Those are opposite requirements, and the schema's delete
-- rules are what hold them apart -- so they are asserted here rather than
-- trusted.

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

select pg_temp.student('c1000000-0000-4000-8000-000000000001');  -- leaves
select pg_temp.student('c1000000-0000-4000-8000-000000000002');  -- stays

-- What the leaving student has: work, a plan, a rubric, spending,
-- a security record, a subscription, and the anti-farming observations.
insert into public.assignments (user_id, title, task_type, deadline, estimated_minutes)
values ('c1000000-0000-4000-8000-000000000001', 'Essay on tides', 'essay',
        now() + interval '7 days', 120);
insert into public.rubrics (user_id, name, source, total_marks)
values ('c1000000-0000-4000-8000-000000000001', 'Mark scheme', 'custom', 20);
insert into public.ai_usage (user_id, kind, model, attempt_state,
                             reserved_cost_microusd, actual_cost_microusd)
values ('c1000000-0000-4000-8000-000000000001', 'breakdown', 'claude-haiku-4-5',
        'completed', 30000, 2600);
insert into public.identity_links (user_id, kind, hash)
values ('c1000000-0000-4000-8000-000000000001', 'device', repeat('a', 64));

insert into public.security_events (user_id, kind, severity)
values ('c1000000-0000-4000-8000-000000000001', 'account_deletion_fixture', 'info');
insert into public.subscription_transactions (original_transaction_id, user_id, environment)
values ('account-deletion-fixture', 'c1000000-0000-4000-8000-000000000001', 'Sandbox');
insert into public.rubric_items (user_id, rubric_id, name, marks)
select user_id, id, 'Evidence', 20 from public.rubrics
where user_id = 'c1000000-0000-4000-8000-000000000001';
insert into public.subtasks (user_id, assignment_id, title, estimated_minutes)
select user_id, id, 'Research tides', 30 from public.assignments
where user_id = 'c1000000-0000-4000-8000-000000000001';

-- And the same for the student who is staying, so a delete that took too much
-- is visible as their rows disappearing too.
insert into public.assignments (user_id, title, task_type, deadline, estimated_minutes)
values ('c1000000-0000-4000-8000-000000000002', 'Lab report', 'essay',
        now() + interval '5 days', 90);

-- -------------------------------------------------------------------------
-- Who may ask.

select ok(not has_function_privilege('anon', 'public.delete_my_account()', 'EXECUTE'),
          'a signed-out caller cannot delete an account');
select ok(has_function_privilege('authenticated', 'public.delete_my_account()', 'EXECUTE'),
          'a signed-in student can delete their own');
select is((select pg_get_function_identity_arguments('public.delete_my_account()'::regprocedure)),
          '',
          'it takes no argument, so no caller can name somebody else''s account');

-- -------------------------------------------------------------------------
-- The deletion itself.

set local role authenticated;
select set_config('request.jwt.claim.sub', 'c1000000-0000-4000-8000-000000000001', true);
select lives_ok($$select public.delete_my_account()$$,
                'the student deletes their own account');
reset role;
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claims', '', true);

select is((select count(*)::integer from auth.users
            where id = 'c1000000-0000-4000-8000-000000000001'), 0,
          'the account is gone');
select is((select count(*)::integer from public.assignments
            where user_id = 'c1000000-0000-4000-8000-000000000001'), 0,
          'and the work they wrote with it');
select is((select count(*)::integer from public.rubrics
            where user_id = 'c1000000-0000-4000-8000-000000000001'), 0,
          'and their saved rubrics');

-- -------------------------------------------------------------------------
-- What must outlive them.

select is((select count(*)::integer from public.identity_links
            where user_id = 'c1000000-0000-4000-8000-000000000001'), 1,
          'the anti-farming observations stay, or deleting resets the free allowance');
select is((select count(*)::integer from public.ai_usage
            where user_id is null and actual_cost_microusd = 2600), 1,
          'what their AI calls cost still counts, with nobody attached');

-- -------------------------------------------------------------------------
select is((select count(*)::integer from public.security_events
            where kind = 'account_deletion_fixture' and user_id is null), 1,
          'security evidence survives without an account owner');
select is((select count(*)::integer from public.subscription_transactions
            where original_transaction_id = 'account-deletion-fixture' and user_id is null), 1,
          'the purchase survives without an account owner');
select is((select count(*)::integer from public.rubric_items
            where user_id = 'c1000000-0000-4000-8000-000000000001'), 0,
          'saved rubric content is erased');
select is((select count(*)::integer from public.subtasks
            where user_id = 'c1000000-0000-4000-8000-000000000001'), 0,
          'planned steps are erased');

-- Nobody else is touched.

select is((select count(*)::integer from auth.users
            where id = 'c1000000-0000-4000-8000-000000000002'), 1,
          'the other student still has an account');
select is((select count(*)::integer from public.assignments
            where user_id = 'c1000000-0000-4000-8000-000000000002'), 1,
          'and still has their work');

-- -------------------------------------------------------------------------
-- Signed out, nothing happens.

reset role;
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claims', '', true);
select throws_ok($$select public.delete_my_account()$$,
                 '28000', 'NOT_SIGNED_IN',
                 'a call with no signed-in student is refused, not silently ignored');

select * from finish();
rollback;
