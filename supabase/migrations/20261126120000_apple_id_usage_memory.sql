-- 20261126120000_apple_id_usage_memory
--
-- Deleting an account and signing in again started the week's free AI plans
-- from zero. Felipe found it at the 24 Nov exhibition: delete, sign in with
-- the same Apple ID, and five more plans. Usage is counted per account, and
-- `delete_my_account` sets `ai_usage.user_id` to null, so the new account
-- inherited nothing. The device signal in `account_risk` (0035) only halves
-- the allowance at about five accounts on one phone in a day, and never
-- blocks on that alone, by design: siblings share iPads.
--
-- Sign in with Apple gives each Apple ID one fixed identifier for this app
-- (`auth.identities.provider_id`), and it is the same after a deletion. So
-- when an account goes, its last 30 days of AI use are linked to a peppered
-- hash of that identifier, and every count of a student's usage also counts
-- the rows linked to their own Apple ID's hash. Deleting and signing in again
-- then changes nothing: the week's plans, the hourly rate, the 30-day
-- fair-use ceiling and the reset time all carry over, the same way a restored
-- purchase already carries them (20260925170000).
--
-- What is kept, and for how long (the privacy page says the same):
--
--   * Only an HMAC-SHA256 of the identifier, keyed with a random pepper made
--     here and kept in Vault. Never the identifier, the email or a name. The
--     pepper never leaves the database, so the hash cannot be matched against
--     anything outside it.
--   * Only links to usage rows from the 30 days before the deletion. A row
--     holds what kind of AI call it was, the model, its cost and when: never
--     what the student wrote. Those rows were already kept, without an owner,
--     for accounting.
--   * Each link goes once its usage row is 30 days old, the longest window
--     anything counts over: daily, by `prune-apple-usage-memory`. So nothing
--     outlives the deletion by more than 30 days.
--
-- Accounts never signed in with Apple (the anonymous ones from before 6 Oct)
-- have no identifier, so nothing is kept for them and nothing changes.
--
-- The hash is made at deletion by a trigger on `auth.users`, so every way an
-- account can go (the app's deletion, the maintenance jobs, the dashboard)
-- leaves the same record. Rows are read before the delete's cascades run, so
-- `ai_usage.user_id` still names the account.

begin;

-- ---------------------------------------------------------------------------
-- 1. The pepper, made once, kept in Vault.

do $$
begin
  if not exists (select 1 from vault.secrets s where s.name = 'albus_apple_id_pepper') then
    perform vault.create_secret(
      encode(extensions.gen_random_bytes(32), 'hex'),
      'albus_apple_id_pepper',
      'Keys the hash of Apple sign-in identifiers kept after an account is deleted. Never leaves the database.');
  end if;
end $$;

-- The account's Apple identifier, hashed with the pepper. Null for an account
-- with no Apple sign-in, and if the pepper is missing: then nothing is linked
-- or matched, and counting is exactly as it was before this migration.
create function private.apple_id_hash(p_uid uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select encode(extensions.hmac(i.provider_id, d.decrypted_secret, 'sha256'), 'hex')
    from auth.identities i
    cross join (
      select s.decrypted_secret from vault.decrypted_secrets s
       where s.name = 'albus_apple_id_pepper'
    ) d
   where i.user_id = p_uid
     and i.provider = 'apple'
     and i.provider_id is not null
   order by i.created_at
   limit 1;
$$;

revoke all on function private.apple_id_hash(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The links: a deleted account's recent usage, by Apple ID hash.

create table private.ai_usage_apple_ids (
  usage_id   uuid not null references public.ai_usage(id) on delete cascade,
  apple_hash text not null check (apple_hash ~ '^[0-9a-f]{64}$'),
  primary key (usage_id, apple_hash)
);

comment on table private.ai_usage_apple_ids is
  'Usage of deleted accounts, linked to a peppered hash of their Apple ID, so deleting and signing in again cannot reset free allowances. Each link goes when its usage row is 30 days old.';

alter table private.ai_usage_apple_ids enable row level security;
revoke all on private.ai_usage_apple_ids from public, anon, authenticated;
create index ai_usage_apple_ids_hash_idx on private.ai_usage_apple_ids (apple_hash);

create function private.remember_apple_usage()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash text := private.apple_id_hash(old.id);
begin
  if v_hash is not null then
    insert into private.ai_usage_apple_ids (usage_id, apple_hash)
      select u.id, v_hash
        from public.ai_usage u
       where u.user_id = old.id
         and u.created_at > now() - interval '30 days'
      on conflict do nothing;
  end if;
  return old;
end;
$$;

revoke all on function private.remember_apple_usage() from public, anon, authenticated;

-- BEFORE, so the identity row and `ai_usage.user_id` are both still there:
-- the delete's cascades and SET NULLs run after the row itself goes.
create trigger remember_apple_usage
  before delete on auth.users
  for each row execute function private.remember_apple_usage();

-- ---------------------------------------------------------------------------
-- 3. Every count of a student's usage includes their Apple ID's links.
--
-- The four functions as 20260925170000 left them, each with one more way a
-- row can belong to the student. A row matches once however many ways it
-- belongs, so nothing is counted twice; the global spend (`ai_global_cost`)
-- sums rows, not students, and is untouched. `(select …)` makes the hash once
-- per call, not once per row.

create or replace function private.ai_account_cost(
  p_uid uuid,
  p_since interval
) returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  -- A terminal call with provider usage pays its measured, server-priced cost.
  -- Anything unfinished or unknown keeps the conservative reservation. A
  -- crashed isolate therefore cannot turn an Anthropic call into free budget.
  select coalesce(sum(
    case
      when u.attempt_state = 'reserved' then u.reserved_cost_microusd
      when u.actual_cost_microusd is not null then u.actual_cost_microusd
      else u.reserved_cost_microusd
    end
  ), 0)::bigint
  from public.ai_usage u
  where (u.user_id = p_uid or exists (
       select 1 from private.ai_usage_purchases l
       join public.subscription_transactions s on s.original_transaction_id=l.original_transaction_id
       where l.usage_id=u.id and s.user_id=p_uid) or exists (
       select 1 from private.ai_usage_apple_ids a
       where a.usage_id=u.id and a.apple_hash=(select private.apple_id_hash(p_uid))))
    and u.created_at > now() - p_since;
$$;

revoke all on function private.ai_account_cost(uuid, interval)
  from public, anon, authenticated;

create or replace function private.ai_attempt_count(
  p_uid uuid,
  p_kind text,
  p_since interval
) returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer
    from public.ai_usage u
   where (u.user_id = p_uid or exists (
       select 1 from private.ai_usage_purchases l
       join public.subscription_transactions s on s.original_transaction_id=l.original_transaction_id
       where l.usage_id=u.id and s.user_id=p_uid) or exists (
       select 1 from private.ai_usage_apple_ids a
       where a.usage_id=u.id and a.apple_hash=(select private.apple_id_hash(p_uid))))
     and u.kind = p_kind
     and u.created_at > now() - p_since;
$$;

revoke all on function private.ai_attempt_count(uuid, text, interval)
  from public, anon, authenticated;

create or replace function public.ai_spend_count(
  p_uid uuid,
  p_kind text,
  p_since interval
) returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer
    from public.ai_usage u
   where (u.user_id = p_uid or exists (
       select 1 from private.ai_usage_purchases l
       join public.subscription_transactions s on s.original_transaction_id=l.original_transaction_id
       where l.usage_id=u.id and s.user_id=p_uid) or exists (
       select 1 from private.ai_usage_apple_ids a
       where a.usage_id=u.id and a.apple_hash=(select private.apple_id_hash(p_uid))))
     and u.kind = p_kind
     and u.created_at > now() - p_since
     and (
          u.attempt_state = 'completed'
       or (u.attempt_state = 'reserved'
           and u.created_at > now() - interval '15 minutes')
     );
$$;

comment on function public.ai_spend_count(uuid, text, interval) is
  'Successful results plus genuinely in-flight reservations, including those of a deleted account with the same Apple ID. Failed attempts do not consume a purchased allowance.';

revoke all on function public.ai_spend_count(uuid, text, interval)
  from public, anon, authenticated;

create or replace function public.ai_window_resets_at(
  p_uid uuid,
  p_kind text,
  p_since interval
) returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select min(u.created_at) + p_since
    from public.ai_usage u
   where (u.user_id = p_uid or exists (
       select 1 from private.ai_usage_purchases l
       join public.subscription_transactions s on s.original_transaction_id=l.original_transaction_id
       where l.usage_id=u.id and s.user_id=p_uid) or exists (
       select 1 from private.ai_usage_apple_ids a
       where a.usage_id=u.id and a.apple_hash=(select private.apple_id_hash(p_uid))))
     and u.kind = p_kind
     and u.created_at > now() - p_since
     and (
          u.attempt_state = 'completed'
       or (u.attempt_state = 'reserved'
           and u.created_at > now() - interval '15 minutes')
     );
$$;

revoke all on function public.ai_window_resets_at(uuid, text, interval)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Nothing outlives its 30 days.

create function private.prune_apple_usage_memory()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_removed integer;
begin
  delete from private.ai_usage_apple_ids l
   using public.ai_usage u
   where l.usage_id = u.id
     and u.created_at <= now() - interval '30 days';
  get diagnostics v_removed = row_count;
  return v_removed;
end;
$$;

revoke all on function private.prune_apple_usage_memory() from public, anon, authenticated;

do $$
begin
  perform cron.unschedule('prune-apple-usage-memory');
exception when others then null;
end $$;

select cron.schedule(
  'prune-apple-usage-memory',
  '17 5 * * *',
  $$select private.prune_apple_usage_memory()$$
);

commit;
