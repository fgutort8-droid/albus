#!/usr/bin/env bash
# Exercise the real gate and real pinned lints; every fixture rolls back in
# the same connection that scans it, so uncommitted DDL is visible to Splinter.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PROJECT=$(sed -nE 's/^project_id = "([^"]+)"/\1/p' "$ROOT/supabase/config.toml")
export ALBUS_DB_CONTAINER=${ALBUS_DB_CONTAINER:-supabase_db_$PROJECT}
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

run_gate() {
  local status=0
  "$ROOT/scripts/security/advisor-lints.sh" "$@" > "$TEST_DIR/output" 2>&1 || status=$?
  return "$status"
}
assert_rollback() {
  local remaining
  remaining=$(docker exec -i "$ALBUS_DB_CONTAINER" psql -U postgres -d postgres -X -qAt -v ON_ERROR_STOP=1 <<'SQL'
select (select count(*) from pg_catalog.pg_class where relname like 'advisor_gate_%')
     + (select count(*) from pg_catalog.pg_proc where proname like 'advisor_gate_%'
        or oid = pg_catalog.to_regprocedure('public.delete_my_account(integer)'));
SQL
)
  [ "$remaining" = 0 ] || fail "fixture DDL survived rollback: $remaining objects"
}
expect_block() {
  local label=$1 lint=$2 object=$3 status=0
  cat > "$TEST_DIR/fixture.sql"
  run_gate --fixture-sql "$TEST_DIR/fixture.sql" || status=$?
  [ "$status" = 1 ] || { cat "$TEST_DIR/output"; fail "$label: expected gate exit 1, got $status"; }
  python3 - "$TEST_DIR/output" "$lint" "$object" <<'PYTHON'
import json, sys
from pathlib import Path
for line in Path(sys.argv[1]).read_text().splitlines():
    if not line.startswith("BLOCK "):
        continue
    prefix, rest = line.split(" object=", 1)
    obj = json.loads(rest.split(" detail=", 1)[0])
    if prefix.split()[-1] == sys.argv[2] and obj.get("name") == sys.argv[3]:
        print(line)
        break
else:
    raise SystemExit("FAIL: expected blocked lint and exact fixture object were not named")
PYTHON
  assert_rollback
  echo "PASS: $label (gate exit 1; fixture rolled back)"
}

run_gate || { cat "$TEST_DIR/output"; fail 'baseline must pass before planting faults'; }
echo 'PASS: clean baseline (gate exit 0)'

expect_block 'public table without RLS' rls_disabled_in_public advisor_gate_no_rls <<'SQL'
create table public.advisor_gate_no_rls (id integer primary key);
grant select on public.advisor_gate_no_rls to authenticated;
SQL

expect_block 'security definer view' security_definer_view advisor_gate_view <<'SQL'
create view public.advisor_gate_view with (security_invoker = false) as select 1 as id;
grant select on public.advisor_gate_view to authenticated;
SQL

expect_block 'mutable function search path' function_search_path_mutable advisor_gate_mutable <<'SQL'
create function public.advisor_gate_mutable() returns integer language sql as $$ select 1 $$;
SQL

expect_block 'policy with RLS disabled' policy_exists_rls_disabled advisor_gate_policy <<'SQL'
create table private.advisor_gate_policy (id integer primary key);
create policy advisor_gate_policy on private.advisor_gate_policy for select to authenticated using (id > 0);
SQL

expect_block 'definer executable by anon' anon_security_definer_function_executable advisor_gate_anon <<'SQL'
create function public.advisor_gate_anon() returns integer language sql security definer set search_path = '' as $$ select 1 $$;
revoke all on function public.advisor_gate_anon() from public, authenticated;
grant execute on function public.advisor_gate_anon() to anon;
SQL

# An allowed lint must not hide another function or a new overload of an
# allowed function; matching includes the complete identity arguments.
expect_block 'different authenticated definer is not allowlisted' authenticated_security_definer_function_executable advisor_gate_authenticated <<'SQL'
create function public.advisor_gate_authenticated() returns integer language sql security definer set search_path = '' as $$ select 1 $$;
revoke all on function public.advisor_gate_authenticated() from public, anon;
grant execute on function public.advisor_gate_authenticated() to authenticated;
SQL

expect_block 'new overload is not allowlisted' authenticated_security_definer_function_executable delete_my_account <<'SQL'
create function public.delete_my_account(p_probe integer) returns integer language plpgsql security definer set search_path = '' as $$ begin return p_probe; end $$;
revoke all on function public.delete_my_account(integer) from public, anon;
grant execute on function public.delete_my_account(integer) to authenticated;
SQL

cat > "$TEST_DIR/fixture.sql" <<'SQL'
create table public.advisor_gate_info (id integer);
alter table public.advisor_gate_info enable row level security;
SQL
run_gate --fixture-sql "$TEST_DIR/fixture.sql" || { cat "$TEST_DIR/output"; fail 'PERFORMANCE and SECURITY INFO must not block'; }
grep -E '^INFO .* (no_primary_key|rls_enabled_no_policy) .*"name": "advisor_gate_info"' "$TEST_DIR/output" > "$TEST_DIR/nonblocking"
[ "$(wc -l < "$TEST_DIR/nonblocking" | tr -d ' ')" = 2 ] || fail 'both non-blocking fixture findings must be printed'
cat "$TEST_DIR/nonblocking"
assert_rollback
echo 'PASS: PERFORMANCE and SECURITY INFO printed without blocking (gate exit 0)'

printf 'select 1/0;\n' > "$TEST_DIR/fixture.sql"
status=0
run_gate --fixture-sql "$TEST_DIR/fixture.sql" || status=$?
[ "$status" = 2 ] && grep -q 'division by zero' "$TEST_DIR/output" || fail 'SQL errors must fail closed with exit 2'
echo 'PASS: SQL execution error fails closed (gate exit 2)'

run_gate || { cat "$TEST_DIR/output"; fail 'clean run after all rollbacks must pass'; }
assert_rollback
tail -1 "$TEST_DIR/output"
echo 'PASS: 5 required faults and 2 allowlist-scope faults caught; clean final run (gate exit 0)'
