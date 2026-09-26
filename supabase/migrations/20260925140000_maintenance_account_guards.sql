-- Account maintenance follows activity, content and billing ownership.
begin;

create or replace function public.reap_abandoned_anonymous_users(older_than_days integer default 30)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_user auth.users%rowtype;
  v_cutoff timestamptz;
  v_column record;
  v_owned boolean;
  v_session_count bigint;
  v_locked_sessions bigint;
  v_removed integer := 0;
begin
  if older_than_days is null or older_than_days < 30 or older_than_days > 36500 then
    raise exception 'INVALID_RETENTION_DAYS' using errcode = '22023';
  end if;
  v_cutoff := now() - make_interval(days => older_than_days);

  for v_id in
    select u.id from auth.users u
     where u.is_anonymous is true and u.created_at < v_cutoff
     order by u.id
  loop
    begin
    -- Maintenance yields to subscription, sign-in and deletion work.
    if not pg_try_advisory_xact_lock(hashtextextended('albus:subscription-owner:' || v_id::text, 0)) then
      raise exception using errcode = 'P0A01';
    end if;
    select * into v_user from auth.users u where u.id = v_id for update skip locked;
    if not found then raise exception using errcode = 'P0A01'; end if;
    if v_user.is_anonymous is not true or v_user.created_at >= v_cutoff
       or v_user.last_sign_in_at >= v_cutoff or v_user.updated_at >= v_cutoff
       or coalesce(v_user.raw_user_meta_data, '{}'::jsonb) <> '{}'::jsonb then
      raise exception using errcode = 'P0A01';
    end if;

    -- A refresh can update a session without changing the parent auth row.
    select count(*) into v_session_count from auth.sessions s where s.user_id = v_id;
    select count(*) into v_locked_sessions from (
      select s.id from auth.sessions s where s.user_id = v_id for update skip locked
    ) locked;
    if v_session_count <> v_locked_sessions then raise exception using errcode = 'P0A01'; end if;
    if exists (
      select 1 from auth.sessions s where s.user_id = v_id
       and (greatest(s.created_at, s.updated_at, s.refreshed_at at time zone 'UTC') >= v_cutoff
            or greatest(s.created_at, s.updated_at, s.refreshed_at at time zone 'UTC') is null)
    ) then raise exception using errcode = 'P0A01'; end if;

    -- The bootstrap profile is empty; edits and onboarding are durable use.
    perform 1 from public.profiles p where p.id = v_id for update skip locked;
    if not found and exists (select 1 from public.profiles p where p.id = v_id) then
      raise exception using errcode = 'P0A01';
    end if;
    if exists (
      select 1 from public.profiles p where p.id = v_id
       and (p.onboarding_completed_at is not null or p.display_name is not null
            or p.curriculum_code is not null or p.daily_study_minutes <> 150
            or p.study_window_start <> time '16:00' or p.study_window_end <> time '22:00'
            or p.updated_at is distinct from p.created_at)
    ) then raise exception using errcode = 'P0A01'; end if;

    -- Include future FK-owned tables and durable user_id observations too.
    -- Catalog identifiers are quoted; the account value remains a parameter.
    for v_column in
      select distinct n.nspname, c.relname, a.attname
        from pg_catalog.pg_attribute a
        join pg_catalog.pg_class c on c.oid = a.attrelid
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
       where n.nspname in ('public', 'private') and c.relkind in ('r', 'p')
         and a.attnum > 0 and not a.attisdropped
         and a.atttypid = 'uuid'::regtype
         and c.oid <> 'public.profiles'::regclass
         and (a.attname = 'user_id' or exists (
           select 1 from pg_catalog.pg_constraint k
            where k.contype = 'f' and k.conrelid = c.oid
              and k.confrelid = 'auth.users'::regclass and a.attnum = any(k.conkey)
         ))
    loop
      execute format('select exists (select 1 from %I.%I where %I = $1)',
                     v_column.nspname, v_column.relname, v_column.attname)
        into v_owned using v_id;
      if v_owned then raise exception using errcode = 'P0A01'; end if;
    end loop;

    delete from auth.users u where u.id = v_id;
    if found then v_removed := v_removed + 1; end if;
    exception when sqlstate 'P0A01' then
      -- Retained accounts release their maintenance locks immediately.
      null;
    end;
    -- Bound locks held by successful deletions until this call commits.
    if v_removed >= 500 then return v_removed; end if;
  end loop;
  return v_removed;
end;
$$;
revoke all on function public.reap_abandoned_anonymous_users(integer) from public, anon, authenticated;
grant execute on function public.reap_abandoned_anonymous_users(integer) to service_role;

-- Keep the transfer destination present for the entire operation.
create or replace function public.transfer_subscriptions(
  p_from uuid[],
  p_to uuid,
  p_event_id text,
  p_event_at timestamptz
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_transaction text;
  v_user        uuid;
  v_previous    uuid[];
  v_moved       integer;
begin
  if p_to is null
     or p_event_id is null or length(p_event_id) > 255
     or p_event_at is null
     or not exists (select 1 from auth.users u where u.id = p_to for key share) then
    return 'invalid';
  end if;

  insert into public.subscription_webhook_events (event_id, event_type)
  values (p_event_id, 'TRANSFER')
  on conflict (event_id) do nothing;
  if not found then return 'stale'; end if;

  -- apply_subscription_state's lock order: transactions first, then accounts,
  -- each in a fixed order. A renewal for one of these transactions either
  -- finishes before the move or starts after it and reads the new owner.
  for v_transaction in
    select s.original_transaction_id
      from public.subscription_transactions s
     where s.user_id = any(coalesce(p_from, '{}'::uuid[]))
     order by 1
  loop
    perform pg_advisory_xact_lock(
      hashtextextended('albus:subscription:' || v_transaction, 0));
  end loop;

  for v_user in
    select distinct t.u
      from unnest(array_append(coalesce(p_from, '{}'::uuid[]), p_to)) as t(u)
     where t.u is not null
     order by 1
  loop
    perform pg_advisory_xact_lock(
      hashtextextended('albus:subscription-owner:' || v_user::text, 0));
  end loop;

  select coalesce(array_agg(distinct s.user_id), '{}'::uuid[]) into v_previous
    from public.subscription_transactions s
   where s.user_id = any(coalesce(p_from, '{}'::uuid[]))
     and s.user_id <> p_to;

  update public.subscription_transactions s
     set user_id = p_to,
         updated_at = now()
   where s.user_id = any(v_previous);
  get diagnostics v_moved = row_count;

  -- The usage follows the plan, or every restore would hand out a fresh set
  -- of limits. 30 days is the longest window any per-account limit reads.
  -- The AI gate's own lock order, global then accounts, so a call already
  -- being checked finishes on the old account and is moved with the rest.
  if v_moved > 0 then
    perform pg_advisory_xact_lock(hashtextextended('albus:ai_usage:global', 0));
    for v_user in
      select distinct t.u
        from unnest(array_append(v_previous, p_to)) as t(u)
       order by 1
    loop
      perform pg_advisory_xact_lock(
        hashtextextended('albus:ai_usage:' || v_user::text, 0));
    end loop;

    update public.ai_usage u
       set user_id = p_to
     where u.user_id = any(v_previous)
       and u.created_at > now() - interval '30 days';
  end if;

  -- Both sides: the old account loses the plan, the new one gains it.
  for v_user in
    select distinct t.u
      from unnest(array_append(coalesce(p_from, '{}'::uuid[]), p_to)) as t(u)
     where t.u is not null
  loop
    perform private.recompute_entitlement(v_user);
  end loop;

  return case when v_moved > 0 then 'transferred' else 'nothing_to_transfer' end;
end;
$$;

revoke all on function public.transfer_subscriptions(uuid[], uuid, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.transfer_subscriptions(uuid[], uuid, text, timestamptz)
  to service_role;


create or replace function public.record_identity_link(
  p_user_id uuid,
  p_kind text,
  p_hash text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer;
begin
  if p_user_id is null or p_kind not in ('device', 'ip_prefix')
     or p_hash is null or p_hash !~ '^[0-9a-f]{64}$' then
    return;
  end if;

  -- Preserve the account while its observation is written. Historical hashes
  -- remain independent of auth.users so deletion does not reset abuse limits.
  perform 1 from auth.users u where u.id = p_user_id for key share;
  if not found then return; end if;

  -- Existing observations are cheap and useful. Do this before taking the lock
  -- so the normal path does not serialize every request from one student.
  update public.identity_links l
     set last_seen_at = now(),
         hit_count = least(2147483647, l.hit_count + 1)
   where l.user_id = p_user_id and l.kind = p_kind and l.hash = p_hash;
  if found then return; end if;

  perform pg_advisory_xact_lock(
    hashtextextended('albus:identity:' || p_user_id::text || ':' || p_kind, 0));

  -- A modified client can send a fresh, UUID-shaped device header each time.
  -- Eight devices and sixteen network prefixes cover real travel/reinstalls;
  -- the seventeenth random value is storage amplification, not identity.
  v_limit := case when p_kind = 'device' then 8 else 16 end;
  if (select count(*) from public.identity_links l
       where l.user_id = p_user_id and l.kind = p_kind) >= v_limit then
    return;
  end if;

  insert into public.identity_links (user_id, kind, hash)
  values (p_user_id, p_kind, p_hash)
  on conflict (user_id, kind, hash) do update
    set last_seen_at = now(),
        hit_count = least(2147483647, public.identity_links.hit_count + 1);
end;
$$;

revoke all on function public.record_identity_link(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.record_identity_link(uuid, text, text)
  to service_role;

commit;
