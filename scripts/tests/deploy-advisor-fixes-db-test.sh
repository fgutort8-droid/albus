#!/usr/bin/env bash
# Run the 3 Nov security-fix script's exact read-only query against a real
# database rebuilt from every migration (CI's local Supabase stack). The
# script's own test fakes the CLI, so only this proves the SQL itself. Each
# planted fault sits in a transaction that is rolled back, and must change
# exactly its own answer.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT=deploy-advisor-fixes-2026-11-03.sh
PROJECT=$(sed -nE 's/^project_id = "([^"]+)"/\1/p' "$ROOT/supabase/config.toml")
DB_CONTAINER=${ALBUS_DB_CONTAINER:-supabase_db_$PROJECT}
fail() { echo "FAIL: $1" >&2; exit 1; }

# A dated script pins the database changes it was reviewed with. Once main
# moves on, the script refuses to run, and there is nothing left to test.
pinned=$(sed -n 's/^MIGRATIONS_DIGEST=//p' "$ROOT/scripts/$SCRIPT")
actual=$(cd "$ROOT" && python3 - <<'PY'
from pathlib import Path
import hashlib
h=hashlib.sha256()
for p in sorted(Path('supabase/migrations').glob('*.sql')): h.update(p.name.encode()+b'\0'+p.read_bytes()+b'\0')
print(h.hexdigest())
PY
)
if [ "$pinned" != "$actual" ]; then
  echo "SKIP $SCRIPT database check: the migrations have changed since this one-time fix was reviewed"
  exit 0
fi

SQL=$(sed -n '/^cat > "\$STAGE\/state.sql" <<.SQL.$/,/^SQL$/p' "$ROOT/scripts/$SCRIPT" | sed '1d;$d')
[ "$(head -1 <<<"$SQL")" = select ] && [ "$(tr -cd ';' <<<"$SQL" | wc -c | tr -d ' ')" = 1 ] \
  || fail "could not find the script's single select in $SCRIPT"
docker inspect "$DB_CONTAINER" >/dev/null 2>&1 || fail "no database container $DB_CONTAINER; run supabase start first"
db() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -X -q -A -t -x -F '=' -v ON_ERROR_STOP=1; }
answers() { grep -E '^[a-z_]+=(t|f)$' | sort | xargs; }
# The fault runs first, its own output discarded, and the whole transaction is
# rolled back.
with() { { echo 'begin;'; echo 'set local client_min_messages = warning;'; echo '\o /dev/null'; printf '%s\n' "$1"; echo '\o'; printf '%s\n' "$SQL"; echo 'rollback;'; } | db | answers; }
expect() { # label, the answers, what they must be
  [ "$2" = "$3" ] || fail "$1: got '$2', expected '$3'"
  echo "PASS: $1"
}

expect 'the migrated database, with the exact query the script sends' "$(printf '%s\n' "$SQL" | db | answers)" \
  'graphql_on=f own_functions_callable=t plans_readable=t'
expect 'GraphQL switched back on' "$(with 'create extension pg_graphql;')" \
  'graphql_on=t own_functions_callable=t plans_readable=t'
expect 'the plans closed to students' "$(with 'revoke select on public.plans from authenticated;')" \
  'graphql_on=f own_functions_callable=t plans_readable=f'
expect "a student's own function closed to them" "$(with 'revoke execute on function public.my_plan() from authenticated;')" \
  'graphql_on=f own_functions_callable=f plans_readable=t'
echo "PASS: $SCRIPT database check, on a real database, with every fault caught."
