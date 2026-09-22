-- Align production's migration bookkeeping with the files in this repo.
--
-- SUPERSEDED. `deploy-2026-09-05.sql` carried out this repair in production on
-- 16 Sep 2026. Kept for its explanation; do not run it.
--
-- WHAT THIS IS NOT: this applies no DDL. It changes only
-- `supabase_migrations.schema_migrations`, the table the Supabase CLI reads to
-- decide what still needs applying. The schema is already correct — a
-- `supabase db reset --local` rebuilds it from the repo files and the pgTAP
-- suite passes against the result. What is wrong is the record of *which file*
-- produced it.
--
-- WHY IT DRIFTED: every migration from `0030` onward was applied by hand
-- through the dashboard. The dashboard stamps its own timestamp rather than
-- reading the filename, so the recorded version is the moment of application,
-- not the migration's identity. `20260901200000_ib_student_context.sql` was
-- applied without being recorded at all.
--
-- WHY IT MATTERS: `supabase db push` applies every migration whose version it
-- does not recognise. Today it would not recognise thirteen of them, and would
-- replay the entire security hardening against a database that already has it.
-- Until this runs, the `Deploy migrations` workflow's secrets must stay unset.
--
-- HOW TO RUN IT: read it, then execute the whole file in one transaction
-- against production. It is idempotent — running it twice changes nothing the
-- second time — and the verification block at the end raises rather than
-- committing a partial repair.

begin;

-- Snapshot first. Rolling back means restoring from this table.
create table if not exists supabase_migrations.schema_migrations_backup_20260903 as
  select * from supabase_migrations.schema_migrations;

-- The eight that were applied as `00NN_*.sql` files.
update supabase_migrations.schema_migrations set version = '0030' where version = '20260826172040' and name = 'grading_free_quota';
update supabase_migrations.schema_migrations set version = '0031' where version = '20260826174458' and name = 'grading_basis_and_allowance';
update supabase_migrations.schema_migrations set version = '0032' where version = '20260826180120' and name = 'grading_reuse';
update supabase_migrations.schema_migrations set version = '0033' where version = '20260826194228' and name = 'final_grade_and_usage_truth';
update supabase_migrations.schema_migrations set version = '0034' where version = '20260827103738' and name = 'three_plans';
update supabase_migrations.schema_migrations set version = '0035' where version = '20260827103842' and name = 'account_risk';
update supabase_migrations.schema_migrations set version = '0036' where version = '20260827104719' and name = 'close_two_bypasses';
update supabase_migrations.schema_migrations set version = '0037' where version = '20260827210655' and name = 'chat_becomes_pro_only';

-- The three timestamped ones, applied on 2026-09-01 but authored earlier.
update supabase_migrations.schema_migrations set version = '20260830104329' where version = '20260901192220' and name = 'production_financial_safety';
update supabase_migrations.schema_migrations set version = '20260830114547' where version = '20260901192432' and name = 'close_direct_write_and_request_abuse';
update supabase_migrations.schema_migrations set version = '20260831174227' where version = '20260901225530' and name = 'drop_scaffold_course_templates';

-- Applied, never recorded. Its DDL is live: `profiles.exam_session`,
-- `courses.level`, `dp_year_for_session()` and `set_ib_context()` all exist.
insert into supabase_migrations.schema_migrations (version, name)
  select '20260901200000', 'ib_student_context'
   where not exists (
     select 1 from supabase_migrations.schema_migrations where version = '20260901200000'
   );

-- Refuse to commit a partial repair. Every version below is a filename in
-- supabase/migrations/; if one is missing, the update above did not match and
-- committing would leave `db push` just as dangerous as before.
do $$
declare
  v_missing text[];
begin
  select array_agg(v order by v) into v_missing
    from unnest(array[
      '0030','0031','0032','0033','0034','0035','0036','0037',
      '20260830104329','20260830114547','20260831174227','20260901200000'
    ]) as v
   where not exists (
     select 1 from supabase_migrations.schema_migrations m where m.version = v
   );

  if v_missing is not null then
    raise exception 'migration history repair incomplete; still missing: %', v_missing;
  end if;
end $$;

commit;
