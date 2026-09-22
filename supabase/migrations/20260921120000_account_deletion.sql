-- 20260921120000_account_deletion
--
-- A student can delete their account from inside the app.
--
-- Required before submission: App Store guideline 5.1.1(v) says an app that
-- creates accounts must offer deletion inside the app, and Albus creates one
-- for every student at the end of onboarding. It is also the GDPR erasure
-- right. Anonymous sign-in must not leave a student without an erasure path.
--
-- The function takes no argument. A caller cannot name an account: it reads
-- auth.uid() from the verified JWT, so the worst a tampered client can do is
-- delete itself. Deleting the auth row is the only statement; every table
-- already declares what should happen to its rows:
--
--   CASCADE, so it is erased with the account -- assignments, subtasks,
--   plan_sessions, courses, profiles, entitlements, rubrics, rubric_items,
--   gradings, completion_logs, private.api_rate_windows and the auth.* rows.
--
--   SET NULL, so the row survives with no owner -- ai_usage and
--   subscription_revenue when billing is installed (accounting must still add up after
--   somebody leaves), security_events, and subscription_transactions (a
--   renewal arriving after the account is gone must not resurrect it, and a
--   restore onto a new account can still move the purchase).
--
--   public.identity_links has no foreign key at all, deliberately: the hashed
--   device and network observations outlive the account for their 90-day
--   window. Without that, "sign up, use the free allowance, delete, repeat"
--   costs an abuser nothing -- see docs/security-model.md section 5.
--
-- What it does NOT do is cancel an Apple subscription; nothing on this side
-- can. The app says so before it asks the student to confirm.

begin;

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_SIGNED_IN' using errcode = '28000';
  end if;

  delete from auth.users u where u.id = v_uid;
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

comment on function public.delete_my_account() is
  'Deletes the calling student''s own account and everything that cascades '
  'from it. Takes no argument on purpose: the id comes from the verified JWT.';

-- Fails the deploy rather than shipping a function anyone can call, or one
-- that trusts a caller-supplied id.
do $$
begin
  if pg_catalog.has_function_privilege('anon', 'public.delete_my_account()', 'execute') then
    raise exception 'anon can execute delete_my_account';
  end if;
  if not pg_catalog.has_function_privilege('authenticated', 'public.delete_my_account()', 'execute') then
    raise exception 'authenticated cannot execute delete_my_account';
  end if;
  if pg_catalog.pg_get_function_identity_arguments(
       'public.delete_my_account()'::regprocedure) <> '' then
    raise exception 'delete_my_account must take no arguments';
  end if;
end
$$;

commit;
