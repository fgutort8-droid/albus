-- Deleting an account and signing in again with the same Apple ID must not
-- reset what the student has used (20261126120000).
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;
select no_plan();

-- a1 and a2 are the same Apple ID before and after a deletion; b is someone
-- else; n never signed in with Apple; d is deleted outside the app.
insert into auth.users (id, instance_id, aud, role, created_at, updated_at, is_anonymous)
select ('a1d00000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid,
       '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', now(), now(), i = 4
  from unnest(array[1, 3, 4, 5]) i;

insert into auth.identities (user_id, provider_id, identity_data, provider, created_at, updated_at)
values
  ('a1d00000-0000-4000-8000-000000000001', 'apple-sub-same-person',
   jsonb_build_object('sub', 'apple-sub-same-person'), 'apple', now(), now()),
  ('a1d00000-0000-4000-8000-000000000003', 'apple-sub-someone-else',
   jsonb_build_object('sub', 'apple-sub-someone-else'), 'apple', now(), now()),
  ('a1d00000-0000-4000-8000-000000000005', 'apple-sub-dashboard',
   jsonb_build_object('sub', 'apple-sub-dashboard'), 'apple', now(), now());

-- The first account's week: five delivered plans and one failed one, plus a
-- plan from 40 days ago that no window counts any more.
insert into public.ai_usage (user_id, kind, model, attempt_state, reserved_cost_microusd,
                             actual_cost_microusd, budget_pool, created_at)
select 'a1d00000-0000-4000-8000-000000000001', 'breakdown', 'claude-sonnet-5', 'completed',
       30000, 2600, 'free', now() - (i || ' hours')::interval
  from generate_series(1, 5) i;
insert into public.ai_usage (user_id, kind, model, attempt_state, reserved_cost_microusd,
                             actual_cost_microusd, budget_pool, created_at)
values
  ('a1d00000-0000-4000-8000-000000000001', 'breakdown', 'claude-sonnet-5', 'failed',
   30000, 0, 'free', now() - interval '30 minutes'),
  ('a1d00000-0000-4000-8000-000000000001', 'breakdown', 'claude-sonnet-5', 'completed',
   30000, 2600, 'free', now() - interval '40 days'),
  ('a1d00000-0000-4000-8000-000000000004', 'breakdown', 'claude-sonnet-5', 'completed',
   30000, 2600, 'free', now() - interval '1 hour');

select is(public.ai_spend_count('a1d00000-0000-4000-8000-000000000001', 'breakdown', interval '7 days'), 5,
  'the first account has used five plans this week');

-- Deleted from the app, as the student would.
set local role authenticated;
select set_config('request.jwt.claim.sub', 'a1d00000-0000-4000-8000-000000000001', true);
select public.delete_my_account();
reset role;

select is((select count(*)::integer from auth.users where id = 'a1d00000-0000-4000-8000-000000000001'), 0,
  'the account is gone');
select is((select count(*)::integer from private.ai_usage_apple_ids), 6,
  'its last 30 days of usage are linked, the failed attempt included, the 40-day-old row not');
select ok((select bool_and(apple_hash ~ '^[0-9a-f]{64}$') from private.ai_usage_apple_ids),
  'only a hash is kept');
select is((select count(*)::integer from private.ai_usage_apple_ids
            where apple_hash like '%apple-sub%'), 0,
  'never the Apple identifier itself');
select is((select count(*)::integer from public.ai_usage u
            join private.ai_usage_apple_ids a on a.usage_id = u.id
           where u.created_at <= now() - interval '30 days'), 0,
  'nothing older than 30 days is linked');

-- The same Apple ID signs in again, as a new account.
insert into auth.users (id, instance_id, aud, role, created_at, updated_at, is_anonymous)
values ('a1d00000-0000-4000-8000-000000000002', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', now(), now(), false);
insert into auth.identities (user_id, provider_id, identity_data, provider, created_at, updated_at)
values ('a1d00000-0000-4000-8000-000000000002', 'apple-sub-same-person',
        jsonb_build_object('sub', 'apple-sub-same-person'), 'apple', now(), now());

select is(private.apple_id_hash('a1d00000-0000-4000-8000-000000000002'),
          (select min(apple_hash) from private.ai_usage_apple_ids),
  'the new account has the same Apple ID hash');
select is(public.ai_spend_count('a1d00000-0000-4000-8000-000000000002', 'breakdown', interval '7 days'), 5,
  'the week''s plans carry over to the new account');
select is(public.ai_window_resets_at('a1d00000-0000-4000-8000-000000000002', 'breakdown', interval '7 days'),
          now() - interval '5 hours' + interval '7 days',
  'and so does the moment they reset');
select is(private.ai_attempt_count('a1d00000-0000-4000-8000-000000000002', 'breakdown', interval '1 hour'), 1,
  'the hourly rate counts the failed attempt too');
select is(private.ai_account_cost('a1d00000-0000-4000-8000-000000000002', interval '30 days'), 13000::bigint,
  'the 30-day fair-use ceiling carries over at real cost');

-- At the real gate: the server function calls this before every AI request.
-- Free keeps five plans a week, all five inherited, so the next is refused
-- and nothing is reserved.
select is((select p.breakdown_per_week from public.plans p where p.tier = 'free'), 5,
  'Free keeps five AI plans a week');
select throws_ok(
  $$select public.check_and_record_ai_usage('a1d00000-0000-4000-8000-000000000002', 'breakdown', 'claude-sonnet-5')$$,
  'Q0006', 'ALLOWANCE_WEEKLY',
  'the gate refuses the new account''s next plan: the week''s five are already used');
select is((select count(*)::integer from public.ai_usage
            where user_id = 'a1d00000-0000-4000-8000-000000000002'), 0,
  'and reserves nothing for it');

-- What the app shows the new account, read as that account.
set local role authenticated;
select set_config('request.jwt.claim.sub', 'a1d00000-0000-4000-8000-000000000002', true);
select is((select breakdown_used_week from public.my_plan()), 5,
  'the app shows the new account all five plans used');
select is((select breakdown_resets_at from public.my_plan()), now() - interval '5 hours' + interval '7 days',
  'and when they come back');
reset role;

-- The new account's own plan counts once, on top of the inherited ones.
insert into public.ai_usage (user_id, kind, model, attempt_state, reserved_cost_microusd,
                             actual_cost_microusd, budget_pool, created_at)
values ('a1d00000-0000-4000-8000-000000000002', 'breakdown', 'claude-sonnet-5', 'completed',
        30000, 2600, 'free', now());
select is(public.ai_spend_count('a1d00000-0000-4000-8000-000000000002', 'breakdown', interval '7 days'), 6,
  'its own plans add to the inherited ones');

-- Nobody else inherits anything.
select is(public.ai_spend_count('a1d00000-0000-4000-8000-000000000003', 'breakdown', interval '7 days'), 0,
  'another Apple ID inherits nothing');
select is(private.apple_id_hash('a1d00000-0000-4000-8000-000000000004'), null,
  'an account with no Apple sign-in has no hash');
select is(public.ai_spend_count('a1d00000-0000-4000-8000-000000000004', 'breakdown', interval '7 days'), 1,
  'and counts only its own usage');

-- The gate still lets a different Apple ID through: the refusal above is the
-- inheritance, not a gate that refuses everyone.
select lives_ok(
  $$select public.check_and_record_ai_usage('a1d00000-0000-4000-8000-000000000003', 'breakdown', 'claude-sonnet-5')$$,
  'the gate lets another Apple ID plan');
select is((select count(*)::integer from public.ai_usage
            where user_id = 'a1d00000-0000-4000-8000-000000000003'), 1,
  'and reserves its plan');

-- Deleted a second time: the chain holds, and nothing is linked twice.
set local role authenticated;
select set_config('request.jwt.claim.sub', 'a1d00000-0000-4000-8000-000000000002', true);
select public.delete_my_account();
reset role;
insert into auth.users (id, instance_id, aud, role, created_at, updated_at, is_anonymous)
values ('a1d00000-0000-4000-8000-000000000006', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', now(), now(), false);
insert into auth.identities (user_id, provider_id, identity_data, provider, created_at, updated_at)
values ('a1d00000-0000-4000-8000-000000000006', 'apple-sub-same-person',
        jsonb_build_object('sub', 'apple-sub-same-person'), 'apple', now(), now());
select is(public.ai_spend_count('a1d00000-0000-4000-8000-000000000006', 'breakdown', interval '7 days'), 6,
  'a third account with the same Apple ID still sees all six');

-- An account with no Apple sign-in leaves nothing behind.
select is((select count(*)::integer from private.ai_usage_apple_ids), 7,
  'six links from the first account and one from the second');
delete from auth.users where id = 'a1d00000-0000-4000-8000-000000000004';
select is((select count(*)::integer from private.ai_usage_apple_ids), 7,
  'deleting an account with no Apple sign-in links nothing');

-- However an account goes, the same record is kept.
insert into public.ai_usage (user_id, kind, model, attempt_state, reserved_cost_microusd,
                             actual_cost_microusd, budget_pool, created_at)
values ('a1d00000-0000-4000-8000-000000000005', 'grade', 'claude-opus-5', 'completed',
        450000, 80000, 'paid', now() - interval '2 days');
delete from auth.users where id = 'a1d00000-0000-4000-8000-000000000005';
select is((select count(*)::integer from private.ai_usage_apple_ids a
             join public.ai_usage u on u.id = a.usage_id where u.kind = 'grade'), 1,
  'an account deleted outside the app is remembered the same way');

-- Money is never counted twice: the rows are the same rows.
-- Nine rows written above, plus the one reservation the gate made for b.
select is((select count(*)::integer from public.ai_usage where model = 'claude-sonnet-5'), 10,
  'linking adds no usage rows');

-- After 30 days each link goes.
update public.ai_usage set created_at = now() - interval '31 days'
 where id = (select u.id from public.ai_usage u join private.ai_usage_apple_ids a on a.usage_id = u.id
              where u.kind = 'breakdown' order by u.created_at desc limit 1);
-- Read over 40 days, so only the link decides whether the old row counts.
select is(private.ai_account_cost('a1d00000-0000-4000-8000-000000000006', interval '40 days'), 15600::bigint,
  'until the clean-up runs, the 31-day-old row still counts through its link');
select is(private.prune_apple_usage_memory(), 1, 'the daily job removes a link once its usage is 30 days old');
select is(private.ai_account_cost('a1d00000-0000-4000-8000-000000000006', interval '40 days'), 13000::bigint,
  'and then it no longer counts');
select is((select count(*)::integer from cron.job where jobname = 'prune-apple-usage-memory'), 1,
  'the job is scheduled');

-- Closed to students: checked by privilege, never by calling as one.
select ok(not has_table_privilege('authenticated', 'private.ai_usage_apple_ids', 'select'),
  'students cannot read the links');
select ok(not has_table_privilege('anon', 'private.ai_usage_apple_ids', 'select'),
  'nor can anyone signed out');
select ok(not has_function_privilege('authenticated', 'private.apple_id_hash(uuid)', 'execute')
      and not has_function_privilege('anon', 'private.apple_id_hash(uuid)', 'execute'),
  'nobody outside the database can make a hash');
select ok(not has_function_privilege('authenticated', 'private.prune_apple_usage_memory()', 'execute')
      and not has_function_privilege('anon', 'private.prune_apple_usage_memory()', 'execute'),
  'nor run the clean-up');
select ok(not has_function_privilege('authenticated', 'private.remember_apple_usage()', 'execute'),
  'nor call the trigger function');
select is((select count(*)::integer from vault.secrets where name = 'albus_apple_id_pepper'), 1,
  'the pepper is in Vault');

select * from finish();
rollback;
