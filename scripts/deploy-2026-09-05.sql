-- One-shot production deploy: history repair + the three pending migrations.
--
-- RAN IN PRODUCTION ON 16 SEP 2026. Kept as the record of what ran; do not run
-- it again. Since 20260917120000_retire_ib_schema it would refuse anyway,
-- because the IB objects it checks for no longer exist.
--
-- WHY THIS IS ONE FILE. Applying a migration through the dashboard (or the
-- MCP apply_migration tool) stamps the *moment of application* as its version,
-- not the version in its filename. That is not a hypothesis: production records
-- `production_financial_safety` as 20260901192220 while its file is
-- 20260830104329, because that is exactly how it was applied. Repairing the
-- history and then hand-applying three more migrations the same way would fix
-- twelve rows and immediately create three more wrong ones.
--
-- So this repairs the history AND applies all three migrations AND records them
-- under their real filename versions, in a single transaction. Afterwards the
-- repaired entries use their filename versions. Compare the complete
-- history with the repository before using `supabase db push` in a later deploy.
--
-- ALL OR NOTHING. Any failure rolls the whole thing back and production is
-- exactly as it was. The verification block at the end raises rather than
-- letting a partial state commit.
--
-- HOW TO RUN: paste the whole file into the Supabase SQL editor and execute.
--   https://supabase.com/dashboard/project/ssvehwhblgqtvqkfbkbj/sql/new

begin;

-- ---------------------------------------------------------------- 1. snapshot
create table if not exists supabase_migrations.schema_migrations_backup_20260905 as
  select * from supabase_migrations.schema_migrations;

-- ------------------------------------------------------- 2. repair the history
-- Bookkeeping only. No schema is touched by this section; every migration
-- below is already applied, it is only recorded under the wrong version.
update supabase_migrations.schema_migrations set version = '0030' where version = '20260826172040' and name = 'grading_free_quota';
update supabase_migrations.schema_migrations set version = '0031' where version = '20260826174458' and name = 'grading_basis_and_allowance';
update supabase_migrations.schema_migrations set version = '0032' where version = '20260826180120' and name = 'grading_reuse';
update supabase_migrations.schema_migrations set version = '0033' where version = '20260826194228' and name = 'final_grade_and_usage_truth';
update supabase_migrations.schema_migrations set version = '0034' where version = '20260827103738' and name = 'three_plans';
update supabase_migrations.schema_migrations set version = '0035' where version = '20260827103842' and name = 'account_risk';
update supabase_migrations.schema_migrations set version = '0036' where version = '20260827104719' and name = 'close_two_bypasses';
update supabase_migrations.schema_migrations set version = '0037' where version = '20260827210655' and name = 'chat_becomes_pro_only';

update supabase_migrations.schema_migrations set version = '20260830104329' where version = '20260901192220' and name = 'production_financial_safety';
update supabase_migrations.schema_migrations set version = '20260830114547' where version = '20260901192432' and name = 'close_direct_write_and_request_abuse';
update supabase_migrations.schema_migrations set version = '20260831174227' where version = '20260901225530' and name = 'drop_scaffold_course_templates';

-- A missing history row does not establish that its migration ran. Refuse to
-- stamp this version unless the student-context columns and RPCs are present.
do $$
begin
  if exists (
    select 1 from (values
      ('profiles', 'exam_session', 'text'),
      ('profiles', 'target_points', 'smallint'),
      ('courses', 'level', 'text'),
      ('courses', 'target_grade', 'smallint')
    ) as expected(table_name, column_name, data_type)
    where not exists (
      select 1 from information_schema.columns c
       where c.table_schema = 'public'
         and c.table_name = expected.table_name
         and c.column_name = expected.column_name
         and c.data_type = expected.data_type
    )
  ) or to_regprocedure('public.dp_year_for_session(text,timestamp with time zone)') is null
    or to_regprocedure('public.create_course(text,text,text,text,smallint)') is null
    or to_regprocedure('public.update_course(uuid,text,smallint,boolean,boolean)') is null
    or to_regprocedure('public.set_ib_context(text,smallint,boolean,boolean)') is null then
    raise exception 'ib_student_context schema is incomplete; refusing to record an unapplied migration';
  end if;
end $$;

insert into supabase_migrations.schema_migrations (version, name)
  select '20260901200000', 'ib_student_context'
   where not exists (select 1 from supabase_migrations.schema_migrations where version = '20260901200000');

-- ------------------------------------------- 3. migration 20260903204500
-- IB task types. Widening a CHECK is safe for existing rows by construction:
-- every value that satisfied the old constraint satisfies this one.
alter table public.assignments
  drop constraint if exists assignments_task_type_check;

alter table public.assignments
  add constraint assignments_task_type_check
  check (task_type in (
    'essay', 'problem_set', 'lab_report', 'reading',
    'revision', 'project', 'presentation', 'other',
    'internal_assessment', 'extended_essay',
    'tok_essay', 'tok_exhibition',
    'mock_exam', 'final_exam'
  ));

comment on column public.assignments.task_type is
  'What kind of work this is. The eight generic shapes plus the six IB assessments. Drives how the planner decomposes the task — an internal assessment and an essay are not the same job.';

insert into supabase_migrations.schema_migrations (version, name)
  select '20260903204500', 'ib_task_types'
   where not exists (select 1 from supabase_migrations.schema_migrations where version = '20260903204500');

-- ------------------------------------------- 4. migration 20260903223000
-- Stop account deletion erasing what it cost. SET NULL anonymises the row
-- rather than deleting it; RLS still hides it, because both policies compare
-- auth.uid() = user_id and NULL = uid is NULL, not true.
alter table public.ai_usage
  alter column user_id drop not null;

alter table public.ai_usage
  drop constraint ai_usage_user_id_fkey;

alter table public.ai_usage
  add constraint ai_usage_user_id_fkey
  foreign key (user_id) references auth.users(id) on delete set null;

insert into supabase_migrations.schema_migrations (version, name)
  select '20260903223000', 'preserve_ai_cost_history'
   where not exists (select 1 from supabase_migrations.schema_migrations where version = '20260903223000');


-- Idempotency guard for re-runs of THIS script.
--
-- The migration below uses bare `create function`, which is correct for a
-- once-only migration but fails the second time a re-runnable script executes
-- it. Dropping the new signatures first keeps the embedded copy verbatim --
-- a deploy script that paraphrases its own migrations is one that drifts from
-- them -- while letting the whole file stay safe to run twice. A rerun
-- restores the same logical state; it still recreates constraints and functions.
drop function if exists private.ai_metered_cost(text, integer, integer, integer, integer);
drop function if exists public.finalize_ai_usage(uuid, text, integer, integer, text, integer, integer);

-- ------------------------------------------- 4b. migration 20260907120000
-- Bill cached tokens. Embedded verbatim from
-- supabase/migrations/20260907120000_bill_cached_tokens.sql -- including its
-- own verification block, which raises inside this transaction if the pricing
-- arithmetic is wrong.
-- Count the tokens Anthropic charges for and we were throwing away.
--
-- **The ledger has been undercounting every cached call since caching was
-- switched on.** `response.usage.input_tokens` from the Anthropic API counts
-- only the tokens that were neither read from cache nor written to it. The
-- other two live in separate fields, and both are billed:
--
--   cache_creation_input_tokens   1.25x the base input rate  (MORE than input)
--   cache_read_input_tokens       0.10x the base input rate
--
-- `generateBreakdown` and `gradeWork` captured `cache_read_input_tokens` and
-- then dropped it on the floor; `chatReply` never captured it at all; and
-- `cache_creation_input_tokens` was captured nowhere, despite being the
-- expensive one. `finalize_ai_usage` took input and output only, so none of it
-- could have reached a cost figure even if the Edge Functions had passed it.
--
-- The blind spot is therefore largest exactly where the money is: a cache write
-- costs 25% more per token than ordinary input and was counted as zero.
--
-- This is not a large sum today -- 43 calls -- but the ledger is the thing the
-- monthly safety ceiling and every reconciliation against the provider's own
-- invoice are computed from. A ceiling that cannot see a quarter of its own
-- spend is not a ceiling, and the gap widens with exactly the traffic caching
-- is meant to make cheap.

alter table public.ai_usage
  add column if not exists cache_write_tokens integer,
  add column if not exists cache_read_tokens integer;

comment on column public.ai_usage.cache_write_tokens is
  'Anthropic cache_creation_input_tokens. Billed at 1.25x the base input rate.';
comment on column public.ai_usage.cache_read_tokens is
  'Anthropic cache_read_input_tokens. Billed at 0.10x the base input rate.';

-- Dropped rather than replaced: `create or replace` with a different argument
-- count creates an overload instead, and two candidates make every existing
-- three-argument call ambiguous.
drop function if exists private.ai_metered_cost(text, integer, integer);

create function private.ai_metered_cost(
  p_model text,
  p_input_tokens integer,
  p_output_tokens integer,
  p_cache_write_tokens integer default 0,
  p_cache_read_tokens integer default 0
) returns bigint
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_input_rate integer;
  v_output_rate integer;
begin
  select p.input_microusd_per_token, p.output_microusd_per_token
    into v_input_rate, v_output_rate
    from private.ai_model_prices p
   where p.model = p_model;

  if not found then
    v_input_rate := 50;
    v_output_rate := 100;
    raise warning 'AI model "%" has no configured token price; using fallback input=50/output=100 micro-USD per token',
      coalesce(p_model, '<null>');
  end if;

  -- **Multiply before dividing, deliberately.** Rates are whole micro-USD per
  -- token and Haiku's input rate is 1, so `rate / 10` for a cache read is zero
  -- in integer arithmetic -- the cheapest model would price its cached tokens
  -- at exactly nothing, which is the bug this migration exists to remove.
  -- Scaling by the multiplier first keeps the result honest; the remaining
  -- truncation is under one micro-USD per call.
  return greatest(0, coalesce(p_input_tokens, 0))::bigint * v_input_rate
       + greatest(0, coalesce(p_output_tokens, 0))::bigint * v_output_rate
       + (greatest(0, coalesce(p_cache_write_tokens, 0))::bigint * v_input_rate * 125) / 100
       + (greatest(0, coalesce(p_cache_read_tokens, 0))::bigint * v_input_rate * 10) / 100;
end;
$$;

revoke all on function private.ai_metered_cost(text, integer, integer, integer, integer)
  from public, anon, authenticated;

-- Same reasoning: drop, then recreate with the two new arguments defaulted.
-- The Edge Functions call this through PostgREST with *named* arguments, so a
-- caller that has not been redeployed yet still resolves to this function and
-- simply gets the previous behaviour -- no window during a deploy where a
-- finalisation fails and leaves a reservation stranded.
drop function if exists public.finalize_ai_usage(uuid, text, integer, integer, text);

create function public.finalize_ai_usage(
  p_usage_id uuid,
  p_state text,
  p_input_tokens integer default null,
  p_output_tokens integer default null,
  p_failure_code text default null,
  p_cache_write_tokens integer default null,
  p_cache_read_tokens integer default null
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_input integer := least(2000000, greatest(0, coalesce(p_input_tokens, 0)));
  v_output integer := least(2000000, greatest(0, coalesce(p_output_tokens, 0)));
  v_cache_write integer := least(2000000, greatest(0, coalesce(p_cache_write_tokens, 0)));
  v_cache_read integer := least(2000000, greatest(0, coalesce(p_cache_read_tokens, 0)));
  v_changed integer;
begin
  if p_state not in ('completed', 'failed') then
    raise exception 'INVALID_USAGE_STATE' using errcode = '22023';
  end if;

  update public.ai_usage u
     set attempt_state = p_state,
         input_tokens = case when p_input_tokens is null then null else v_input end,
         output_tokens = case when p_output_tokens is null then null else v_output end,
         cache_write_tokens = case when p_cache_write_tokens is null then null else v_cache_write end,
         cache_read_tokens = case when p_cache_read_tokens is null then null else v_cache_read end,
         -- Unchanged rule: a row with no token evidence at all keeps its
         -- conservative reservation rather than becoming free. Cache tokens
         -- alone are enough evidence to price a call, because a request that
         -- read its whole prompt from cache genuinely has near-zero fresh input.
         actual_cost_microusd = case
           when p_input_tokens is null and p_output_tokens is null
                and p_cache_write_tokens is null and p_cache_read_tokens is null then null
           else least(
             10000000::bigint,
             private.ai_metered_cost(u.model, v_input, v_output, v_cache_write, v_cache_read)
           )::integer
           end,
         failure_code = case when p_state = 'failed'
                             then left(coalesce(p_failure_code, 'UNKNOWN'), 64)
                             else null end,
         finished_at = now()
   where u.id = p_usage_id
     and u.attempt_state = 'reserved';

  get diagnostics v_changed = row_count;
  return v_changed = 1;
end;
$$;

revoke all on function public.finalize_ai_usage(uuid, text, integer, integer, text, integer, integer)
  from public, anon, authenticated;
grant execute on function public.finalize_ai_usage(uuid, text, integer, integer, text, integer, integer)
  to service_role;

-- Prove the pricing, rather than trusting the arithmetic above.
do $$
declare
  v_cost bigint;
begin
  -- Sonnet: input 2, output 10 micro-USD per token.
  -- 1000 input + 100 output + 1000 cache writes + 10000 cache reads
  --   = 2000 + 1000 + (1000*2*125/100 = 2500) + (10000*2*10/100 = 2000) = 7500
  select private.ai_metered_cost('claude-sonnet-5', 1000, 100, 1000, 10000) into v_cost;
  if v_cost <> 7500 then
    raise exception 'sonnet cache pricing is %, expected 7500', v_cost;
  end if;

  -- Haiku input rate is 1, the case integer division would silently zero.
  -- 10000 cache reads = 10000*1*10/100 = 1000, NOT 0.
  select private.ai_metered_cost('claude-haiku-4-5', 0, 0, 0, 10000) into v_cost;
  if v_cost <> 1000 then
    raise exception 'haiku cache reads priced at %, expected 1000 (integer division bug)', v_cost;
  end if;

  -- A cache write must cost more than the same number of ordinary input tokens.
  if private.ai_metered_cost('claude-opus-5', 0, 0, 1000, 0)
     <= private.ai_metered_cost('claude-opus-5', 1000, 0, 0, 0) then
    raise exception 'a cache write is not priced above ordinary input';
  end if;

  -- Old three-argument behaviour must be unchanged when no cache is involved.
  if private.ai_metered_cost('claude-sonnet-5', 1412, 316) <> 5984 then
    raise exception 'uncached pricing changed; expected 1412*2 + 316*10 = 5984';
  end if;
end $$;

insert into supabase_migrations.schema_migrations (version, name)
  select '20260907120000', 'bill_cached_tokens'
   where not exists (select 1 from supabase_migrations.schema_migrations where version = '20260907120000');

-- ------------------------------------------------------------- 5. verify
-- Refuse to commit anything partial.
do $$
declare
  v_missing text[];
  v_rule    text;
  v_notnull boolean;
  v_types   boolean;
begin
  -- A correct version attached to the wrong name is still false history.
  select array_agg(expected.version || '_' || expected.name order by expected.version)
    into v_missing
    from (values
      ('0030', 'grading_free_quota'),
      ('0031', 'grading_basis_and_allowance'),
      ('0032', 'grading_reuse'),
      ('0033', 'final_grade_and_usage_truth'),
      ('0034', 'three_plans'),
      ('0035', 'account_risk'),
      ('0036', 'close_two_bypasses'),
      ('0037', 'chat_becomes_pro_only'),
      ('20260830104329', 'production_financial_safety'),
      ('20260830114547', 'close_direct_write_and_request_abuse'),
      ('20260831174227', 'drop_scaffold_course_templates'),
      ('20260901200000', 'ib_student_context'),
      ('20260903204500', 'ib_task_types'),
      ('20260903223000', 'preserve_ai_cost_history'),
      ('20260907120000', 'bill_cached_tokens')
    ) as expected(version, name)
   where not exists (
     select 1 from supabase_migrations.schema_migrations m
      where m.version = expected.version and m.name = expected.name
   );
  if v_missing is not null then
    raise exception 'history missing expected version/name pairs: %', v_missing;
  end if;

  -- And none of the old, wrongly-stamped versions may survive.
  if exists (
    select 1 from supabase_migrations.schema_migrations
     where version in ('20260826172040','20260826174458','20260826180120','20260826194228',
                       '20260827103738','20260827103842','20260827104719','20260827210655',
                       '20260901192220','20260901192432','20260901225530')
  ) then
    raise exception 'a wrongly-stamped version survived the repair';
  end if;

  select pg_get_constraintdef(oid) like all (array[
      '%''internal_assessment''%', '%''extended_essay''%',
      '%''tok_essay''%', '%''tok_exhibition''%',
      '%''mock_exam''%', '%''final_exam''%'
    ]) into v_types
    from pg_constraint
   where conrelid = 'public.assignments'::regclass
     and conname = 'assignments_task_type_check'
     and contype = 'c';
  if not coalesce(v_types, false) then
    raise exception 'assignments_task_type_check does not include the IB types';
  end if;

  select case con.confdeltype when 'n' then 'SET NULL' when 'c' then 'CASCADE' end
    into v_rule
    from pg_constraint con
   where con.conrelid = 'public.ai_usage'::regclass
     and con.contype = 'f' and con.conname = 'ai_usage_user_id_fkey';
  if v_rule is distinct from 'SET NULL' then
    raise exception 'ai_usage.user_id delete rule is %, expected SET NULL', v_rule;
  end if;

  select attnotnull into v_notnull
    from pg_attribute
   where attrelid = 'public.ai_usage'::regclass and attname = 'user_id';
  if v_notnull then
    raise exception 'ai_usage.user_id is still NOT NULL; SET NULL could never fire';
  end if;

  if exists (
    select 1 from unnest(array['cache_write_tokens', 'cache_read_tokens']) as expected(column_name)
     where not exists (
       select 1 from information_schema.columns c
        where c.table_schema = 'public' and c.table_name = 'ai_usage'
          and c.column_name = expected.column_name and c.data_type = 'integer'
     )
  ) then
    raise exception 'ai_usage cache token columns must both exist as integer; cached spend would be unreliable';
  end if;

  raise notice 'deploy verified: repaired version/name pairs match, all three migrations applied';
end $$;

commit;
