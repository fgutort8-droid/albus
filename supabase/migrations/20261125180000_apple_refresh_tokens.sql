-- Deleting an account without signing in again.
--
-- Sign in with Apple accounts must be revoked with Apple when they are deleted
-- (App Review guideline 5.1.1(v)). Revoking needs a token Apple issued for the
-- account, and until now the only way to get one was a fresh authorization
-- code from Apple's sign-in sheet, shown right before deletion: Felipe found
-- that being asked to sign in to delete reads as an obstacle.
--
-- So the refresh token Apple issues at sign-in is kept, and deletion revokes
-- with it. The app sends the sign-in's authorization code to the `apple-token`
-- function, which exchanges it with Apple and stores the refresh token here;
-- `delete-account` takes it back out to revoke. An account with no token
-- stored (one that signed in before this) still uses the sheet, once.
--
-- The token is a credential, so it is kept in Supabase Vault, encrypted, and
-- this table holds only the secret's id. Nothing a student can call reaches
-- either: the schema is closed to clients, and the two functions below are
-- executable by the server's service role only.

create table private.apple_refresh_tokens (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  secret_id uuid not null unique,
  stored_at timestamptz not null default now()
);
alter table private.apple_refresh_tokens enable row level security;
revoke all on private.apple_refresh_tokens from public, anon, authenticated, service_role;

comment on table private.apple_refresh_tokens is
  'Which Vault secret holds each account''s Apple refresh token, for revoking '
  'Sign in with Apple when the account is deleted. The token itself is in Vault.';

-- However a row goes (deletion takes it, a newer sign-in replaces it, or the
-- account is erased some other way and the row cascades), its Vault secret
-- goes with it: no token outlives the account it belonged to.
create function private.forget_apple_refresh_token()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from vault.secrets s where s.id = old.secret_id;
  return old;
end;
$$;
revoke all on function private.forget_apple_refresh_token() from public, anon, authenticated;

create trigger apple_refresh_tokens_forget
  after delete or update of secret_id on private.apple_refresh_tokens
  for each row execute function private.forget_apple_refresh_token();

-- Keeps the newest token for an account, replacing any earlier one.
create function public.store_apple_refresh_token(p_user_id uuid, p_token text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_secret uuid;
begin
  if p_user_id is null or p_token is null
     or char_length(p_token) not between 1 and 2048 then
    raise exception 'INVALID_TOKEN' using errcode = '22023';
  end if;
  -- One account at a time, so two sign-ins racing cannot leave an orphan.
  perform pg_advisory_xact_lock(hashtextextended('albus:apple_token:' || p_user_id::text, 0));

  v_secret := vault.create_secret(p_token, null, 'Apple refresh token');
  insert into private.apple_refresh_tokens (user_id, secret_id)
  values (p_user_id, v_secret)
  on conflict (user_id) do update
    set secret_id = excluded.secret_id, stored_at = now();
end;
$$;

-- Hands the token back and forgets it, for revoking at deletion. Null when
-- none is stored. Taken rather than read: once it has been used to revoke,
-- Apple no longer honours it, so there is nothing worth keeping.
create function public.take_apple_refresh_token(p_user_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_secret uuid;
  v_token  text;
begin
  if p_user_id is null then
    return null;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('albus:apple_token:' || p_user_id::text, 0));

  select t.secret_id into v_secret
    from private.apple_refresh_tokens t where t.user_id = p_user_id;
  if v_secret is null then
    return null;
  end if;
  select d.decrypted_secret into v_token
    from vault.decrypted_secrets d where d.id = v_secret;
  delete from private.apple_refresh_tokens t where t.user_id = p_user_id;
  return v_token;
end;
$$;

revoke all on function public.store_apple_refresh_token(uuid, text) from public, anon, authenticated;
revoke all on function public.take_apple_refresh_token(uuid) from public, anon, authenticated;
grant execute on function public.store_apple_refresh_token(uuid, text) to service_role;
grant execute on function public.take_apple_refresh_token(uuid) to service_role;

-- Fails the deploy rather than shipping a token a student could reach.
do $$
begin
  if pg_catalog.has_function_privilege('anon', 'public.store_apple_refresh_token(uuid, text)', 'execute')
     or pg_catalog.has_function_privilege('authenticated', 'public.store_apple_refresh_token(uuid, text)', 'execute')
     or pg_catalog.has_function_privilege('anon', 'public.take_apple_refresh_token(uuid)', 'execute')
     or pg_catalog.has_function_privilege('authenticated', 'public.take_apple_refresh_token(uuid)', 'execute') then
    raise exception 'a student can reach the Apple refresh token functions';
  end if;
  if pg_catalog.has_table_privilege('authenticated', 'private.apple_refresh_tokens', 'select')
     or pg_catalog.has_table_privilege('anon', 'private.apple_refresh_tokens', 'select') then
    raise exception 'a student can read private.apple_refresh_tokens';
  end if;
end
$$;
