#!/usr/bin/env bash
# Proves migration 20260917120000_retire_ib_schema against the LOCAL database,
# starting from the schema production had when it was written: every migration
# before it.
#
# The pgTAP suite can only see the schema after a migration has run. This
# script checks what happens while it runs, through `supabase migration up`,
# which applies it the same way `supabase db push` does:
#
#   1. Converts. A student with one task of each retired type keeps every row.
#      Each row changes type exactly as the migration's table says. (First, the
#      new pgTAP file must fail against the old schema, or it proves nothing.)
#   2. Refuses. If a profile or course still holds IB context, the migration
#      fails and the schema, the rows and the migration history are unchanged.
#   3. All or nothing. If the migration's last check fails, after every other
#      statement has run, all of it is undone.
#   4. A full reset applies it, and the new pgTAP file passes.
#
# LOCAL ONLY: every supabase command passes --local. The local stack must be
# running (`supabase start`). A reset discards local data.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET=20260917120000
TEST_FILE=supabase/tests/courses_and_task_types_test.sql
VERSIONS=$(ls supabase/migrations | sed -n 's/^\([0-9]*\)_.*\.sql$/\1/p' | sort)
BEFORE=$(awk -v t="$TARGET" '$1 < t' <<<"$VERSIONS" | tail -1)
LATEST=$(tail -1 <<<"$VERSIONS")
DB="supabase_db_$(sed -n 's/^project_id *= *"\(.*\)"/\1/p' supabase/config.toml)"
USER_ID=20000000-0000-4000-8000-000000000001
COURSE_ID=20000000-0000-4000-8000-0000000000c1
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail=0
pass() { printf 'PASS %s\n' "$1"; }
bad()  { printf 'FAIL %s\n' "$1"; fail=1; }
sql()  { docker exec -i "$DB" psql -U postgres -X -A -t -q -v ON_ERROR_STOP=1 "$@"; }
# The pgTAP file, run to the end whatever happens; prints its TAP lines.
tap()  { docker exec -i "$DB" psql -U postgres -X -A -t -q <"$TEST_FILE" 2>&1 || true; }

# Rebuilds the database up to version $1, then checks it got there. `db reset`
# restarts the other local services after rebuilding, and it fails if one of
# them is slow to report healthy. On a busy machine that is usually storage,
# and the database is already complete by then. That one failure is tolerated.
# The version check is what this proof relies on. Anything else stops here.
db_reset() {
  local want=$1; shift
  if ! supabase db reset --local --no-seed --yes "$@" >"$WORK/reset.log" 2>&1; then
    if grep -q "^Restarting containers" "$WORK/reset.log" \
       && grep -q "container is not ready" "$WORK/reset.log"; then
      echo "     (a local service was slow to restart after the rebuild; checking the database itself)"
    else
      tail -40 "$WORK/reset.log"; exit 1
    fi
  fi
  local got
  got=$(sql -c "select max(version) from supabase_migrations.schema_migrations" 2>&1) || got="unreadable: $got"
  [ "$got" = "$want" ] || { tail -40 "$WORK/reset.log"; echo "reset reached '$got', not $want"; exit 1; }
}

reset_to_before() { db_reset "$BEFORE" --version "$BEFORE"; }

# `supabase migration up`, logged to $1, returning its status. Two steps below
# expect it to fail, so a CLI that cannot reach the database at all would pass
# them for the wrong reason. That case stops the whole proof instead: it says
# nothing about the migration either way.
migrate_up() {
  local status=0
  supabase migration up --local >"$1" 2>&1 || status=$?
  if grep -q "failed to connect to postgres" "$1"; then
    tail -5 "$1"
    echo "ABORTED: the CLI could not reach the local database, so this run proves nothing."
    echo "Rerun it when the machine is less busy."
    exit 2
  fi
  return "$status"
}

# One student, one course, and one task of each retired type plus a generic
# one. Five are active, the free plan's limit. The plan-limit trigger stays on.
seed() {
  sql <<SQL
insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous)
values ('$USER_ID', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        null, '', '{}', '{}', now(), now(), true);
insert into public.courses (id, user_id, display_name, color_key)
values ('$COURSE_ID', '$USER_ID', 'Biology', 'violet');
insert into public.assignments (user_id, course_id, title, task_type, deadline, estimated_minutes, status)
select '$USER_ID', '$COURSE_ID', 'Probe ' || t.name, t.name, now() + interval '30 days', 120, t.status
  from (values ('internal_assessment', 'active'), ('extended_essay', 'active'),
               ('tok_essay', 'active'), ('tok_exhibition', 'active'),
               ('mock_exam', 'completed'), ('final_exam', 'completed'),
               ('essay', 'active')) as t(name, status);
SQL
}

rows()        { sql -c "select id || ' ' || task_type || ' ' || status from public.assignments order by id"; }
fingerprint() {
  sql <<'SQL'
select md5(concat_ws('|',
  (select string_agg(table_name || '.' || column_name, ',' order by table_name, column_name)
     from information_schema.columns
    where table_schema = 'public' and table_name in ('profiles', 'courses')),
  (select pg_get_constraintdef(oid) from pg_constraint
    where conrelid = 'public.assignments'::regclass and conname = 'assignments_task_type_check'),
  (select string_agg(oid::regprocedure::text || md5(prosrc), ',' order by oid::regprocedure::text)
     from pg_proc
    where pronamespace = 'public'::regnamespace
      and proname in ('create_course', 'update_course', 'set_ib_context', 'dp_year_for_session')),
  (select string_agg(id || task_type || updated_at, ',' order by id) from public.assignments),
  (select string_agg(id || coalesce(exam_session, '-') || updated_at, ',' order by id) from public.profiles),
  (select string_agg(version, ',' order by version) from supabase_migrations.schema_migrations)))
SQL
}

echo "Migration under test: $TARGET. Starting point: $BEFORE."

echo
echo "1. Converts every retired type and keeps every row"
reset_to_before
tap >"$WORK/tap-before.txt"
failing=$(grep -c '^not ok' "$WORK/tap-before.txt" || true)
[ "$failing" -gt 0 ] \
  && pass "the new pgTAP file fails against the old schema ($failing assertions before it stops)" \
  || { bad "the new pgTAP file does not notice the old schema"; cat "$WORK/tap-before.txt"; }
seed
rows >"$WORK/before.txt"
sed -e 's/ internal_assessment / project /' -e 's/ extended_essay / essay /' \
    -e 's/ tok_essay / essay /' -e 's/ tok_exhibition / project /' \
    -e 's/ mock_exam / revision /' -e 's/ final_exam / revision /' \
    "$WORK/before.txt" >"$WORK/expected.txt"
if migrate_up "$WORK/up.log"; then
  pass "the migration applied"
else
  bad "the migration failed on convertible data"; cat "$WORK/up.log"
fi
grep -i "converted" "$WORK/up.log" | sed 's/^/     /' || true
rows >"$WORK/after.txt"
echo "     before:"; sed 's/^/       /' "$WORK/before.txt"
echo "     after:";  sed 's/^/       /' "$WORK/after.txt"
if diff -u "$WORK/expected.txt" "$WORK/after.txt"; then
  pass "all $(wc -l <"$WORK/after.txt" | tr -d ' ') rows kept, each converted as documented"
else
  bad "rows differ from the documented conversion"
fi
[ "$(sql -c "select count(*) from supabase_migrations.schema_migrations where version = '$TARGET'")" = 1 ] \
  && pass "history records $TARGET" || bad "history does not record $TARGET"

echo
echo "2. Refuses, and changes nothing, while IB context holds a value"
reset_to_before
seed
sql -c "update public.profiles set exam_session = '2027-05' where id = '$USER_ID'"
sql -c "update public.courses set level = 'HL' where id = '$COURSE_ID'"
before_fp=$(fingerprint)
if migrate_up "$WORK/refuse.log"; then
  bad "the migration applied over IB context it should have refused to drop"
else
  pass "the migration refused"
fi
grep -o "IB_CONTEXT_HAS_DATA[^\"]*" "$WORK/refuse.log" | head -1 | sed 's/^/     /' \
  || { bad "the refusal did not name IB_CONTEXT_HAS_DATA"; cat "$WORK/refuse.log"; }
[ "$(fingerprint)" = "$before_fp" ] \
  && pass "schema, rows, profile values and history are byte-for-byte unchanged" \
  || bad "the refused migration changed something"

echo
echo "3. Fails at its last check, after every change has run, and keeps none of them"
reset_to_before
seed
# A routine that still names a dropped column: exactly what the final check
# exists to catch, and it runs only after every drop and conversion.
sql -c "create function public.zz_reads_exam_session() returns text language sql as \$\$ select 'exam_session' \$\$"
before_fp=$(fingerprint)
if migrate_up "$WORK/late.log"; then
  bad "the migration applied despite a routine naming a retired column"
else
  pass "the migration failed at its final check"
fi
grep -o "a routine still refers to a retired IB name" "$WORK/late.log" | head -1 | sed 's/^/     /' \
  || { bad "it failed for a different reason"; cat "$WORK/late.log"; }
[ "$(fingerprint)" = "$before_fp" ] \
  && pass "no conversion, drop or rewrite survived: all byte-for-byte unchanged" \
  || bad "a failed migration left part of its work behind"

echo
echo "4. Back to every migration"
db_reset "$LATEST"
[ "$(sql -c "select count(*) from supabase_migrations.schema_migrations where version = '$TARGET'")" = 1 ] \
  && pass "a full reset applies $TARGET" \
  || bad "a full reset did not apply $TARGET"
tap >"$WORK/tap-after.txt"
if grep -q '^not ok' "$WORK/tap-after.txt" || ! grep -q '^1\.\.' "$WORK/tap-after.txt"; then
  bad "the new pgTAP file does not pass"; cat "$WORK/tap-after.txt"
else
  pass "the new pgTAP file passes ($(grep -c '^ok' "$WORK/tap-after.txt") assertions)"
fi

echo
[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES ABOVE"
exit "$fail"
