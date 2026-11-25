-- The Apple refresh token kept at sign-in, so deleting an account needs no
-- second sign-in (migration 20261125180000).
--
-- What this defends: only the server reaches the token; it is kept in Vault,
-- not in a readable column; a newer sign-in replaces it without leaving the
-- old secret behind; taking it forgets it; and erasing the account, however
-- that happens, takes the secret with it.

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
    'authenticated', 'authenticated', null, '', '{}', '{}', now(), now(), false
  );
$$;

create function pg_temp.secret_of(p_id uuid) returns uuid language sql as $$
  select t.secret_id from private.apple_refresh_tokens t where t.user_id = p_id;
$$;

select pg_temp.student('a7000000-0000-4000-8000-000000000001');
select pg_temp.student('a7000000-0000-4000-8000-000000000002');

-- ── Who may reach it ────────────────────────────────────────────────────────
select ok(not has_function_privilege('anon', 'public.store_apple_refresh_token(uuid, text)', 'EXECUTE'),
          'anon cannot keep a token');
select ok(not has_function_privilege('authenticated', 'public.store_apple_refresh_token(uuid, text)', 'EXECUTE'),
          'a student cannot keep a token, for themselves or anyone');
select ok(not has_function_privilege('anon', 'public.take_apple_refresh_token(uuid)', 'EXECUTE'),
          'anon cannot take a token');
select ok(not has_function_privilege('authenticated', 'public.take_apple_refresh_token(uuid)', 'EXECUTE'),
          'a student cannot read a token back');
select ok(has_function_privilege('service_role', 'public.store_apple_refresh_token(uuid, text)', 'EXECUTE'),
          'the server can keep a token');
select ok(has_function_privilege('service_role', 'public.take_apple_refresh_token(uuid)', 'EXECUTE'),
          'the server can take a token');
select ok(not has_table_privilege('authenticated', 'private.apple_refresh_tokens', 'SELECT'),
          'a student cannot read the token table');
select ok(not has_table_privilege('service_role', 'private.apple_refresh_tokens', 'SELECT'),
          'not even the server reads the table directly; only the two functions do');

-- The privileges above are Postgres's own check, the one a student's call
-- meets. The call itself is not made here as a student: on the Postgres image
-- CI pins (supabase/postgres 17.6.1.106), any refused function call after this
-- test's login switches role crashes the server, whatever the function, even
-- in an empty database. A student's real call arrives through the API's
-- `authenticator` login, where the same image refuses it cleanly (checked by
-- hand, 25 Nov 2026); newer images (17.11) refuse both cleanly.

-- ── Kept in Vault, replaced, taken ──────────────────────────────────────────
set local role service_role;
select lives_ok($$select public.store_apple_refresh_token('a7000000-0000-4000-8000-000000000001', 'first-token')$$,
                'the server keeps a token');
reset role;

select is((select d.decrypted_secret from vault.decrypted_secrets d
            where d.id = pg_temp.secret_of('a7000000-0000-4000-8000-000000000001')),
          'first-token', 'the token is in Vault');
select is((select count(*)::integer from vault.secrets s
            where s.id = pg_temp.secret_of('a7000000-0000-4000-8000-000000000001')
              and s.secret = 'first-token'),
          0, 'and Vault holds it encrypted, not as written');

create temp table first_secret as
  select pg_temp.secret_of('a7000000-0000-4000-8000-000000000001') as id;

set local role service_role;
select lives_ok($$select public.store_apple_refresh_token('a7000000-0000-4000-8000-000000000001', 'second-token')$$,
                'a newer sign-in keeps its token');
reset role;

select is((select count(*)::integer from private.apple_refresh_tokens
            where user_id = 'a7000000-0000-4000-8000-000000000001'),
          1, 'one token per account');
select is((select count(*)::integer from vault.secrets s where s.id = (select id from first_secret)),
          0, 'the replaced token''s secret is gone');

set local role service_role;
select is(public.take_apple_refresh_token('a7000000-0000-4000-8000-000000000001'),
          'second-token', 'taking hands back the newest token');
select is(public.take_apple_refresh_token('a7000000-0000-4000-8000-000000000001'),
          null, 'and forgets it: there is nothing to take twice');
select is(public.take_apple_refresh_token('a7000000-0000-4000-8000-000000000002'),
          null, 'an account that never kept one has none');
select throws_ok($$select public.store_apple_refresh_token('a7000000-0000-4000-8000-000000000002', '')$$,
                 '22023', 'INVALID_TOKEN', 'an empty token is refused');
select throws_ok($$select public.store_apple_refresh_token('a7000000-0000-4000-8000-000000000002', repeat('x', 2049))$$,
                 '22023', 'INVALID_TOKEN', 'an oversized token is refused');
reset role;
select is((select count(*)::integer from vault.secrets s
            where s.description = 'Apple refresh token'
              and not exists (select 1 from private.apple_refresh_tokens t where t.secret_id = s.id)),
          0, 'no Apple token secret is left without its account');

-- ── Erasing the account takes the secret with it ────────────────────────────
set local role service_role;
select public.store_apple_refresh_token('a7000000-0000-4000-8000-000000000002', 'erased-token');
reset role;
create temp table erased_secret as
  select pg_temp.secret_of('a7000000-0000-4000-8000-000000000002') as id;
delete from auth.users where id = 'a7000000-0000-4000-8000-000000000002';
select is((select count(*)::integer from private.apple_refresh_tokens
            where user_id = 'a7000000-0000-4000-8000-000000000002'),
          0, 'the row goes with the account');
select is((select count(*)::integer from vault.secrets s where s.id = (select id from erased_secret)),
          0, 'and so does its secret');

select * from finish();
rollback;
