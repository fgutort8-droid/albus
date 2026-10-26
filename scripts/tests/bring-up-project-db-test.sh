#!/usr/bin/env bash
# Run the new-project setup script's exact read-only database checks against a
# real database rebuilt from every migration (CI's local Supabase stack). The
# setup test fakes the CLI, so only this proves the SQL itself. Each planted
# fault sits in a transaction that is rolled back, and must turn exactly its
# own checks false. Supabase's automatic-RLS function, which the new project
# has and no migration creates, must leave every check true.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT=bring-up-project-2026-10-25.sh
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
  echo "SKIP $SCRIPT database checks: the migrations have changed since this one-time setup was reviewed"
  exit 0
fi

SQL=$(sed -n '/^cat > "\$STAGE\/verify.sql" <<.SQL.$/,/^SQL$/p' "$ROOT/scripts/$SCRIPT" | sed '1d;$d')
[ "$(head -1 <<<"$SQL")" = select ] && [[ "$(tail -1 <<<"$SQL")" == *' as audit_immutable;' ]] \
  || fail "could not find the checks in $SCRIPT"
# Supabase CLI 2.122 sends the file as one prepared statement, which refuses several.
[ "$(tr -cd ';' <<<"$SQL" | wc -c | tr -d ' ')" = 1 ] || fail 'the checks must be a single statement'
CHECKS=$SQL
docker inspect "$DB_CONTAINER" >/dev/null 2>&1 || fail "no database container $DB_CONTAINER; run supabase start first"
db() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -X -q -A -t -x -F '=' -v ON_ERROR_STOP=1; }
# One key=value line per check. The fault runs first, its own output discarded,
# and the whole transaction is rolled back.
checks() { { echo 'begin;'; echo 'set local client_min_messages = warning;'; echo '\o /dev/null'; printf '%s\n' "$1"; echo '\o'; printf '%s\n' "$CHECKS"; echo 'rollback;'; } | db; }
expect() { # label, the checks' output, the checks that must be false (none: '')
  local got want
  [ "$(grep -c -E '^[a-z_]+=(t|f)$' <<<"$2")" = 15 ] || { printf '%s\n' "$2" >&2; fail "$1: expected 15 checks"; }
  got=$(sed -n 's/=f$//p' <<<"$2" | sort | xargs)
  want=$(tr ' ' '\n' <<<"$3" | sed '/^$/d' | sort | xargs)
  [ "$got" = "$want" ] || fail "$1: false checks were '${got:-none}', expected '${want:-none}'"
  echo "PASS: $1"
}

expect 'the migrated database, with the exact query the script sends' "$(printf '%s\n' "$SQL" | db)" ''
PLATFORM=$(cat "$ROOT/scripts/tests/fixtures/supabase-auto-enable-rls.sql")
expect "Supabase's automatic-RLS function, as the new project has it" "$(checks "$PLATFORM")" ''

expect 'a plan missing' "$(checks "set local session_replication_role = replica; delete from public.plans where tier = 'pro';")" plans_seeded
expect 'the product mappings missing' "$(checks 'set local session_replication_role = replica; delete from public.subscription_products;')" products_mapped
expect 'RLS off on a public table' "$(checks 'alter table public.plans disable row level security;')" public_tables_have_rls
expect 'a public table open to anon' "$(checks 'grant select on public.plans to anon;')" anon_has_no_table_access
expect 'a public view open to anon' "$(checks 'create view public.plan_names as select tier from public.plans; grant select on public.plan_names to anon;')" anon_has_no_table_access
expect 'a definer function with an open path' "$(checks 'create function public.open_path() returns int language sql security definer as $$ select 1 $$;')" definer_paths_closed
expect 'another definer function pinned to pg_catalog' "$(checks 'create function public.pinned() returns int language sql security definer set search_path = pg_catalog as $$ select 1 $$;')" definer_paths_closed
expect "Supabase's function with its path reset" "$(checks "$PLATFORM
alter function public.rls_auto_enable() reset search_path;")" definer_paths_closed
expect "Supabase's function with its path changed" "$(checks "$PLATFORM
alter function public.rls_auto_enable() set search_path = public;")" definer_paths_closed
expect "Supabase's function with a second setting" "$(checks "$PLATFORM
alter function public.rls_auto_enable() set statement_timeout = 0;")" definer_paths_closed
expect 'another event-trigger function in its shape' "$(checks 'create function public.other_trigger() returns event_trigger language plpgsql security definer set search_path = pg_catalog as $$ begin end $$;')" definer_paths_closed
expect 'its name on a function that is not an event trigger' "$(checks 'create function public.rls_auto_enable(int) returns int language sql security definer set search_path = pg_catalog as $$ select 1 $$;')" definer_paths_closed
expect 'its exact shape in private' "$(checks 'create function private.rls_auto_enable() returns event_trigger language plpgsql security definer set search_path = pg_catalog as $$ begin end $$;')" definer_paths_closed
expect 'a scheduled job dropped' "$(checks "select cron.unschedule('prune-security-data');")" jobs_scheduled
expect 'a scheduled job paused' "$(checks "select cron.alter_job((select jobid from cron.job where jobname = 'albus-financial-drain'), active := false);")" jobs_scheduled
expect 'the task cap trigger off' "$(checks 'alter table public.assignments disable trigger assignments_active_limit;')" task_cap_trigger_on
expect 'task sync with other parameters' "$(checks 'drop function public.sync_my_assignments(uuid[], uuid[]); create function public.sync_my_assignments(a uuid[], b uuid[]) returns void language plpgsql as $$ begin end $$;')" 'sync_signature sync_privileges'
expect 'task release with another parameter' "$(checks 'drop function public.release_my_other_assignments(uuid[]); create function public.release_my_other_assignments(k uuid[]) returns void language plpgsql as $$ begin end $$;')" 'release_signature release_privileges'
expect 'task sync open to anon' "$(checks 'grant execute on function public.sync_my_assignments(uuid[], uuid[]) to anon;')" sync_privileges
expect 'task release closed to students' "$(checks 'revoke execute on function public.release_my_other_assignments(uuid[]) from authenticated;')" release_privileges
expect 'account deletion open to anon' "$(checks 'grant execute on function public.delete_my_account() to anon;')" delete_rpc_privileges
expect 'RLS off on the payment queue' "$(checks 'alter table private.financial_inbox disable row level security;')" inbox_rls
expect 'the payment queue open to students' "$(checks 'grant select on private.financial_inbox to authenticated;')" inbox_clients_closed
expect 'the audit log made editable' "$(checks 'grant update on private.financial_audit to service_role;')" audit_immutable
echo "PASS: $SCRIPT database checks, on a real database, with every fault caught."
