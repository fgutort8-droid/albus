begin;

create function public.sync_my_assignments(p_finished uuid[], p_open uuid[])
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_finished uuid[] := pg_catalog.array_remove(coalesce(p_finished, '{}'::uuid[]), null);
  v_open uuid[] := pg_catalog.array_remove(coalesce(p_open, '{}'::uuid[]), null);
  v_id uuid;
  v_changed integer := 0;
  v_rows integer;
begin
  if v_uid is null then
    raise exception 'NOT_SIGNED_IN' using errcode = '28000';
  end if;
  if pg_catalog.cardinality(p_finished) > 500 or pg_catalog.cardinality(p_open) > 500 then
    raise exception 'TOO_MANY_IDS' using errcode = '22023';
  end if;

  -- Same lock as the active-task trigger. Take it before any row lock, so
  -- concurrent sync/release/create calls agree on lock order and task count.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('albus:assignments:' || v_uid::text, 0));
  update public.assignments a set status = 'completed'
   where a.user_id = v_uid and a.status = 'active'
     and a.id = any(v_finished) and not (a.id = any(v_open));
  get diagnostics v_changed = row_count;

  for v_id in
    select a.id from public.assignments a
     where a.user_id = v_uid and a.status = 'completed'
       and a.id = any(v_open) and not (a.id = any(v_finished))
     order by a.id
  loop
    begin
      -- The normal status trigger still enforces the cap for each reopen.
      update public.assignments a set status = 'active'
       where a.id = v_id and a.user_id = v_uid and a.status = 'completed';
      get diagnostics v_rows = row_count;
      v_changed := v_changed + v_rows;
    exception when sqlstate 'Q0001' then
      if sqlerrm <> 'PLAN_TASK_LIMIT_REACHED' then raise; end if;
    end;
  end loop;
  return v_changed;
end;
$$;
revoke all on function public.sync_my_assignments(uuid[], uuid[]) from public, anon;
grant execute on function public.sync_my_assignments(uuid[], uuid[]) to authenticated;
comment on function public.sync_my_assignments(uuid[], uuid[]) is
  'Syncs the calling student''s finished/open tasks, finishing first and skipping '
  'reopens refused by the existing active-task cap; archived and conflicting ids stay unchanged.';

create function public.release_my_other_assignments(p_keep uuid[])
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_keep uuid[] := pg_catalog.array_remove(coalesce(p_keep, '{}'::uuid[]), null);
  v_changed integer;
begin
  if v_uid is null then
    raise exception 'NOT_SIGNED_IN' using errcode = '28000';
  end if;
  if pg_catalog.cardinality(p_keep) > 500 then
    raise exception 'TOO_MANY_IDS' using errcode = '22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('albus:assignments:' || v_uid::text, 0));
  update public.assignments a set status = 'archived'
   where a.user_id = v_uid and a.status = 'active' and not (a.id = any(v_keep));
  get diagnostics v_changed = row_count;
  return v_changed;
end;
$$;
revoke all on function public.release_my_other_assignments(uuid[]) from public, anon;
grant execute on function public.release_my_other_assignments(uuid[]) to authenticated;
comment on function public.release_my_other_assignments(uuid[]) is
  'Archives the calling student''s active tasks absent from this phone''s keep list; '
  'preserves their children, gradings and all other students'' rows.';

do $$
declare
  v_signature text;
  v_expected text;
  v_proc pg_catalog.pg_proc%rowtype;
begin
  for v_signature, v_expected in
    select * from (values
      ('public.sync_my_assignments(uuid[],uuid[])', 'p_finished uuid[], p_open uuid[]'),
      ('public.release_my_other_assignments(uuid[])', 'p_keep uuid[]')
    ) as signatures(signature, arguments)
  loop
    if pg_catalog.has_function_privilege('anon', v_signature, 'execute') then
      raise exception 'anon can execute %', v_signature;
    end if;
    if not pg_catalog.has_function_privilege('authenticated', v_signature, 'execute') then
      raise exception 'authenticated cannot execute %', v_signature;
    end if;
    if pg_catalog.pg_get_function_identity_arguments(v_signature::regprocedure) <> v_expected then
      raise exception 'unexpected identity arguments for %', v_signature;
    end if;
    select * into strict v_proc from pg_catalog.pg_proc where oid = v_signature::regprocedure;
    if not v_proc.prosecdef or not ('search_path=""' = any(coalesce(v_proc.proconfig, '{}'::text[]))) then
      raise exception 'unsafe execution configuration for %', v_signature;
    end if;
  end loop;
end;
$$;

commit;
