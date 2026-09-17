-- Subjects and task types, after the IB layer was retired.
--
-- 20260917120000 dropped the IB context columns and routines, rewrote
-- create_course without its level and target-grade arguments, and narrowed
-- task_type to the eight generic shapes. These tests pin what a student can
-- still do, and that nothing retired can be reached any more.

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

-- True if the column accepts the value. The insert runs in a subtransaction,
-- so a refusal leaves nothing behind.
create function pg_temp.accepts_task_type(p_user uuid, p_type text)
returns boolean language plpgsql as $$
begin
  insert into public.assignments (user_id, title, task_type, deadline, estimated_minutes, status)
  values (p_user, 'Type ' || p_type, p_type, now() + interval '1 day', 30, 'completed');
  return true;
exception when check_violation then
  return false;
end;
$$;

select pg_temp.student('30000000-0000-4000-8000-000000000001');
select pg_temp.student('30000000-0000-4000-8000-000000000002');

-- ---------------------------------------------------------------------------
-- What was retired is gone

select hasnt_column('public', 'profiles', 'exam_session', 'profiles.exam_session is gone');
select hasnt_column('public', 'profiles', 'target_points', 'profiles.target_points is gone');
select hasnt_column('public', 'courses', 'level', 'courses.level is gone');
select hasnt_column('public', 'courses', 'target_grade', 'courses.target_grade is gone');

select is(
  (select count(*)::integer from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('set_ib_context', 'update_course', 'dp_year_for_session')),
  0,
  'no IB routine survives under any signature'
);

select is(
  (select array_agg(p.oid::regprocedure::text) from pg_proc p
    where p.pronamespace = 'public'::regnamespace and p.proname = 'create_course'),
  array['create_course(text,text,text)'],
  'create_course exists once, with three arguments'
);

-- ---------------------------------------------------------------------------
-- create_course: who may call it

select ok(
  has_function_privilege('authenticated', 'public.create_course(text,text,text)', 'EXECUTE'),
  'a signed-in student can create a subject'
);
select ok(
  not has_function_privilege('anon', 'public.create_course(text,text,text)', 'EXECUTE'),
  'a caller without a session cannot'
);
select ok(
  not exists (
    select 1
      from pg_proc p, aclexplode(p.proacl) a
     where p.oid = 'public.create_course(text,text,text)'::regprocedure
       and a.grantee not in (p.proowner, 'authenticated'::regrole::oid)
  ),
  'nobody but the owner and authenticated holds a grant, PUBLIC included'
);
select is(
  (select p.prosecdef::text || ' ' || array_to_string(p.proconfig, ',') from pg_proc p
    where p.oid = 'public.create_course(text,text,text)'::regprocedure),
  'true search_path=""',
  'create_course keeps its security definer posture and empty search path'
);

-- A template to link to. Nothing seeds one any more, so the test brings its own.
insert into public.curricula (code, name) values ('TEST_CURRICULUM', 'Test curriculum');
insert into public.course_templates (id, curriculum_code, code, name)
values ('3000000c-0000-4000-8000-000000000001', 'TEST_CURRICULUM', 'TEST_TEMPLATE', 'Test course');

-- ---------------------------------------------------------------------------
-- create_course: what it does

set local role authenticated;
select set_config('request.jwt.claim.sub', '', true);

select throws_ok(
  $$select public.create_course('No session', 'violet')$$,
  '28000'::character(5), 'NOT_AUTHENTICATED',
  'without a session the RPC refuses before writing'
);

select set_config('request.jwt.claim.sub', '30000000-0000-4000-8000-000000000001', true);

select lives_ok(
  $$select set_config('test.course_id', public.create_course('Biology', 'red')::text, true)$$,
  'a student creates a subject with a name and a colour'
);
select results_eq(
  $$select user_id, display_name, color_key, course_template_id from public.courses
     where id = current_setting('test.course_id')::uuid$$,
  $$values ('30000000-0000-4000-8000-000000000001'::uuid, 'Biology'::text, 'red'::text, null::uuid)$$,
  'the subject belongs to the caller, as named, with no template'
);

-- Each subject is created in its own statement and read back in the next. A
-- statement cannot see a row that a function it calls inserts, so reading it
-- back in the same statement would find nothing, and a check for "no template"
-- would pass for the wrong reason.
select lives_ok(
  $$select set_config('test.default_id', public.create_course('Default colour')::text, true)$$,
  'the colour and template arguments are optional'
);
select results_eq(
  $$select color_key, course_template_id from public.courses
     where id = current_setting('test.default_id')::uuid$$,
  $$values ('violet'::text, null::uuid)$$,
  'an omitted colour is violet, and no template is linked'
);

select lives_ok(
  $$select set_config('test.linked_id',
                      public.create_course('Linked', 'amber', 'TEST_TEMPLATE')::text, true)$$,
  'a subject can name a template'
);
select is(
  (select course_template_id from public.courses
    where id = current_setting('test.linked_id')::uuid),
  '3000000c-0000-4000-8000-000000000001'::uuid,
  'a known template code links the subject to it'
);

select lives_ok(
  $$select set_config('test.unlinked_id',
                      public.create_course('Unlinked', 'amber', 'NO_SUCH_TEMPLATE')::text, true)$$,
  'an unknown template code still creates the subject'
);
select results_eq(
  $$select display_name, course_template_id from public.courses
     where id = current_setting('test.unlinked_id')::uuid$$,
  $$values ('Unlinked'::text, null::uuid)$$,
  'and links nothing'
);

-- What an app built before this change would send. PostgREST matches an RPC by
-- argument names, so this is the call that no longer resolves.
select throws_ok(
  $$select public.create_course(p_display_name => 'Old app', p_color_key => 'violet',
                                p_template_code => null, p_level => null,
                                p_target_grade => null::smallint)$$,
  '42883'::character(5), null,
  'the retired level and target-grade arguments are no longer accepted'
);

-- The ceiling moved into the rewritten function with everything else. The
-- caller already has four subjects, so 46 more reach the limit of 50.
select lives_ok($$
  do $body$
  begin
    for i in 1..46 loop
      perform public.create_course('Subject ' || i, 'violet');
    end loop;
  end
  $body$
$$, 'a student can hold fifty subjects');
select is(
  (select count(*)::integer from public.courses
    where user_id = '30000000-0000-4000-8000-000000000001'),
  50,
  'and does'
);
select throws_ok(
  $$select public.create_course('Fifty-first', 'violet')$$,
  'Q0015'::character(5), 'COURSE_CEILING',
  'the fifty-first is refused'
);

-- Another student's ceiling is their own.
select set_config('request.jwt.claim.sub', '30000000-0000-4000-8000-000000000002', true);
select lives_ok(
  $$select public.create_course('Mine', 'violet')$$,
  'one student at the ceiling does not block another'
);
select is(
  (select count(*)::integer from public.courses),
  1,
  'and RLS still shows each student only their own subjects'
);

-- A task type the constraint refuses is refused on the real write path too.
select throws_ok(
  $$select public.create_assignment_with_plan(
      'IB leftover', 'internal_assessment', now() + interval '7 days', 60,
      '[{"title":"Draft","estimated_minutes":60}]'::jsonb,
      null, null, null, null, 'normal')$$,
  '23514'::character(5), null,
  'the assignment RPC cannot store a retired task type'
);
select lives_ok(
  $$select public.create_assignment_with_plan(
      'Coursework', 'project', now() + interval '7 days', 60,
      '[{"title":"Draft","estimated_minutes":60}]'::jsonb,
      null, null, null, null, 'normal')$$,
  'the assignment RPC stores a generic one'
);

reset role;

-- ---------------------------------------------------------------------------
-- Task types: exactly the eight generic shapes

select is(
  array(
    select t.name
      from unnest(array[
        'essay', 'problem_set', 'lab_report', 'reading',
        'revision', 'project', 'presentation', 'other',
        'internal_assessment', 'extended_essay', 'tok_essay',
        'tok_exhibition', 'mock_exam', 'final_exam',
        'exam', 'Essay', ''
      ]) as t(name)
     where pg_temp.accepts_task_type('30000000-0000-4000-8000-000000000002', t.name)
     order by t.name collate "C"
  ),
  array['essay', 'lab_report', 'other', 'presentation',
        'problem_set', 'project', 'reading', 'revision'],
  'task_type accepts the eight generic shapes and nothing else'
);

select is(
  (select count(*)::integer from public.assignments
    where task_type not in ('essay', 'problem_set', 'lab_report', 'reading',
                            'revision', 'project', 'presentation', 'other')),
  0,
  'no stored assignment carries any other type'
);

select * from finish();
rollback;
