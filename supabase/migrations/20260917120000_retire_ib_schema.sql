-- 20260917120000_retire_ib_schema
--
-- Albus plans study hours for any student. This retires the last IB-only
-- schema, which 20260909180000 kept for one reason only:
-- `scripts/deploy-2026-09-05.sql` refused to record `ib_student_context`
-- unless it found these objects. That deploy ran on 16 Sep 2026, so the
-- reason is gone.
--
-- WHAT THIS RETIRES
--
--   profiles.exam_session, profiles.target_points
--   courses.level, courses.target_grade
--   set_ib_context(), update_course(), dp_year_for_session()
--   create_course()'s p_level and p_target_grade parameters
--   the six IB values in assignments_task_type_check
--
-- WHO STILL CALLS WHAT, checked on 17 Sep 2026 across `ios/` and
-- `supabase/functions/`:
--
--   * set_ib_context and dp_year_for_session: nothing.
--   * update_course: only `ProfileService.updateCourse`, which nothing called.
--     It is deleted in the same change.
--   * create_course: the app, which sent null for p_level and p_target_grade.
--     It now sends only the three arguments kept here. PostgREST matches an RPC
--     by the names it is given, so the new app also works against the old
--     five-argument function, whichever of the two ships first.
--   * The six task types: the app offered them, and `breakdown` accepted them.
--     The app no longer offers them. `breakdown` now converts them to a
--     generic type for any build older than that, and it must be deployed
--     BEFORE this migration. Otherwise an old build can pay for a plan that
--     this constraint then refuses to save.
--
-- WHAT PRODUCTION HELD, read-only on 17 Sep 2026: 34 assignments (30 essay,
-- 2 project, 1 revision, 1 other), no IB task type anywhere; 20 profiles and
-- 5 courses, with none of the four columns set.
--
-- No student row is deleted. An assignment of a retired type is converted to
-- the generic shape that plans the same way. The conversion is idempotent, and
-- it reports what it changed. A column is dropped only if it is empty: if a
-- value has appeared since that read, the migration stops, nothing changes,
-- and dropping a student's data becomes a decision someone makes on purpose.

begin;

-- 1. Refuse to discard a value a student entered.
do $$
declare
  v_profiles integer;
  v_courses integer;
begin
  select count(*) into v_profiles
    from public.profiles p
   where p.exam_session is not null or p.target_points is not null;
  select count(*) into v_courses
    from public.courses c
   where c.level is not null or c.target_grade is not null;

  if v_profiles > 0 or v_courses > 0 then
    raise exception 'IB_CONTEXT_HAS_DATA: % profile(s) and % course(s) still hold IB context; nothing was changed',
      v_profiles, v_courses
      using hint = 'Export or clear those values deliberately, then run this migration again.';
  end if;
end $$;

-- 2. Convert any assignment of a retired type before the constraint narrows.
--
--   internal_assessment -> project   a long, criteria-marked, multi-stage piece
--   extended_essay      -> essay     a 4,000-word essay
--   tok_essay           -> essay     an essay on a prescribed title
--   tok_exhibition      -> project   objects plus a commentary, not a talk
--   mock_exam           -> revision  practice and review, nothing to hand in
--   final_exam          -> revision  the same work at higher stakes
--
-- These match `TaskType(storedValue:)` in the app and `LEGACY_TASK_TYPES` in
-- `breakdown`, so a task has the same type wherever it is read.
--
-- Only `assignments_set_updated_at` fires on this update: the owner, course,
-- rubric and plan-limit triggers watch other columns. `updated_at` moving is
-- accurate, because the row changed.
do $$
declare
  v_converted integer;
begin
  update public.assignments a
     set task_type = case a.task_type
           when 'internal_assessment' then 'project'
           when 'extended_essay' then 'essay'
           when 'tok_essay' then 'essay'
           when 'tok_exhibition' then 'project'
           when 'mock_exam' then 'revision'
           when 'final_exam' then 'revision'
         end
   where a.task_type in ('internal_assessment', 'extended_essay', 'tok_essay',
                         'tok_exhibition', 'mock_exam', 'final_exam');
  get diagnostics v_converted = row_count;
  raise notice 'retire_ib_schema: converted % assignment(s) from an IB task type', v_converted;
end $$;

-- 3. The generic eight, as 0004 had them. Every surviving row satisfies this,
--    and adding the constraint checks each row, so a missed conversion fails
--    here and rolls everything back.
alter table public.assignments
  drop constraint assignments_task_type_check;

alter table public.assignments
  add constraint assignments_task_type_check
  check (task_type in (
    'essay', 'problem_set', 'lab_report', 'reading',
    'revision', 'project', 'presentation', 'other'
  ));

comment on column public.assignments.task_type is
  'What kind of work this is: one of eight generic shapes. Drives how the planner breaks the task down. Must match TaskType in the iOS app and TASK_TYPES in the breakdown Edge Function.';

-- 4. The IB routines. `if exists`, so the result does not depend on how an
--    environment got here. The checks at the end are the guarantee.
drop function if exists public.set_ib_context(text, smallint, boolean, boolean);
drop function if exists public.update_course(uuid, text, smallint, boolean, boolean);
drop function if exists public.dp_year_for_session(text, timestamptz);

-- 5. create_course without the IB arguments. The old signature is dropped
--    first, so there is never a moment with two overloads for PostgREST to
--    choose between. The body is the live one (identical in production, by
--    md5) minus the level and target-grade handling.
drop function if exists public.create_course(text, text, text, text, smallint);

create or replace function public.create_course(
  p_display_name text,
  p_color_key text default 'violet',
  p_template_code text default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_template uuid;
  v_id uuid;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED' using errcode = '28000';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('albus:courses:' || v_uid::text, 0));
  if (select count(*) from public.courses c where c.user_id = v_uid) >= 50 then
    raise exception 'COURSE_CEILING' using errcode = 'Q0015';
  end if;

  if p_template_code is not null then
    select ct.id into v_template
      from public.course_templates ct
     where ct.code = left(p_template_code, 80)
     limit 1;
  end if;

  insert into public.courses (user_id, course_template_id, display_name, color_key)
  values (v_uid, v_template, p_display_name, coalesce(p_color_key, 'violet'))
  returning id into v_id;
  return v_id;
end;
$$;

-- Explicit, so the result does not depend on an environment's default
-- privileges. It leaves the same ACL the five-argument function had.
revoke all on function public.create_course(text, text, text)
  from public, anon, authenticated, service_role;
grant execute on function public.create_course(text, text, text)
  to authenticated;

comment on function public.create_course(text, text, text) is
  'Creates a subject for the calling student and returns its id. The owner comes from the session, never from an argument.';

-- 6. The columns. Each one's CHECK constraint, and any column privilege on it,
--    goes with it. Step 1 already proved them empty.
alter table public.profiles
  drop column exam_session,
  drop column target_points;

alter table public.courses
  drop column level,
  drop column target_grade;

-- 7. Verify the result, not the intent.
do $$
declare
  v_def text;
  v_proc pg_proc%rowtype;
begin
  if exists (
    select 1 from information_schema.columns c
     where c.table_schema = 'public'
       and ((c.table_name = 'profiles' and c.column_name in ('exam_session', 'target_points'))
         or (c.table_name = 'courses' and c.column_name in ('level', 'target_grade')))
  ) then
    raise exception 'an IB context column survived the drop';
  end if;

  if exists (
    select 1 from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proname in ('set_ib_context', 'update_course', 'dp_year_for_session')
  ) then
    raise exception 'an IB routine survived the drop';
  end if;

  -- Exactly one create_course: the three-argument one, as locked down as before.
  if (select count(*) from pg_proc p
       where p.pronamespace = 'public'::regnamespace
         and p.proname = 'create_course') <> 1
     or to_regprocedure('public.create_course(text,text,text)') is null then
    raise exception 'create_course is not exactly the three-argument function';
  end if;

  select * into v_proc from pg_proc
   where oid = 'public.create_course(text,text,text)'::regprocedure;
  if not v_proc.prosecdef
     or v_proc.proconfig is distinct from array['search_path=""']
     or v_proc.prosrc ~* '(level|target_grade)' then
    raise exception 'create_course does not have the expected definition';
  end if;
  -- The owner and `authenticated`, nobody else: not PUBLIC (grantee 0), not
  -- anon, not service_role.
  if has_function_privilege('anon', 'public.create_course(text,text,text)', 'EXECUTE')
     or exists (
       select 1 from aclexplode(v_proc.proacl) a
        where a.grantee not in (v_proc.proowner, 'authenticated'::regrole::oid)
     )
     or not exists (
       select 1 from aclexplode(v_proc.proacl) a
        where a.grantee = 'authenticated'::regrole::oid
          and a.privilege_type = 'EXECUTE'
     ) then
    raise exception 'create_course has the wrong grants: %', v_proc.proacl;
  end if;

  -- The constraint is present and validated, names none of the six, and names
  -- all eight.
  select pg_get_constraintdef(c.oid) into v_def
    from pg_constraint c
   where c.conrelid = 'public.assignments'::regclass
     and c.conname = 'assignments_task_type_check'
     and c.contype = 'c'
     and c.convalidated;
  if v_def is null then
    raise exception 'assignments_task_type_check is missing or not validated';
  end if;
  if v_def ~ '(internal_assessment|extended_essay|tok_essay|tok_exhibition|mock_exam|final_exam)' then
    raise exception 'assignments_task_type_check still accepts an IB type: %', v_def;
  end if;
  if (select count(*)
        from unnest(array['essay', 'problem_set', 'lab_report', 'reading',
                          'revision', 'project', 'presentation', 'other']) as t(name)
       where strpos(v_def, '''' || t.name || '''') > 0) <> 8 then
    raise exception 'assignments_task_type_check lost a generic type: %', v_def;
  end if;

  -- Nothing left in the database still reads what was removed. A PL/pgSQL body
  -- that names a dropped column fails only when it runs, so this is the check
  -- that finds it now rather than in front of a student.
  if exists (
    select 1 from pg_proc p
     where p.pronamespace in ('public'::regnamespace, 'private'::regnamespace)
       and p.prosrc ~* '(exam_session|target_points|target_grade|set_ib_context|update_course|dp_year_for_session|internal_assessment|extended_essay|tok_essay|tok_exhibition|mock_exam|final_exam)'
  ) then
    raise exception 'a routine still refers to a retired IB name';
  end if;
end $$;

commit;
