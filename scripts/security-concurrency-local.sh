#!/usr/bin/env bash
# Real multi-connection attacks against the local Supabase database.
# pgTAP is intentionally single-connection; it cannot prove a lock works.
set -euo pipefail

PROJECT_REF=$(sed -nE 's/^project_id = "([^"]+)"/\1/p' supabase/config.toml)
if [ -n "${ALBUS_AUDIT_PROJECT:-}" ] && [ "$PROJECT_REF" != "$ALBUS_AUDIT_PROJECT" ]; then
  echo 'STOP: configured project does not match the requested audit project' >&2
  exit 1
fi
DB_CONTAINER="supabase_db_${PROJECT_REF}"
TEST_USER_ID='40000000-0000-4000-8000-000000000001'
FREE_USER_ID='41000000-0000-4000-8000-000000000001'
COLLISION_USER_PREFIX='42000000-0000-4000-8000-'
COLLISION_RUBRIC_ID='43000000-0000-4000-8000-000000000001'
RESTORE_FROM_ID='44000000-0000-4000-8000-000000000001'
RESTORE_TO_ID='44000000-0000-4000-8000-000000000002'
TEST_OUTPUT_DIR=$(mktemp -d)

db() {
  docker exec "$DB_CONTAINER" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 "$@"
}

assert_race_outcomes() {
  local prefix=$1
  local expected_error=$2
  local successes=0
  local expected_denials=0
  local unexpected=0
  local i status output

  for i in $(seq 1 12); do
    status=$(<"$TEST_OUTPUT_DIR/$prefix-$i.status")
    output="$TEST_OUTPUT_DIR/$prefix-$i"
    if [ "$status" -eq 0 ] && grep -Eq '^[0-9a-f]{8}-[0-9a-f-]{27}$' "$output"; then
      successes=$((successes + 1))
    elif [ "$status" -ne 0 ] && grep -q "$expected_error" "$output"; then
      expected_denials=$((expected_denials + 1))
    else
      unexpected=$((unexpected + 1))
      echo "unexpected $prefix racer $i (status $status):" >&2
      sed -n '1,8p' "$output" >&2
    fi
  done

  if [ "$successes" -ne 1 ] || [ "$expected_denials" -ne 11 ] || [ "$unexpected" -ne 0 ]; then
    echo "$prefix race outcomes failed: success=$successes expected_denial=$expected_denials unexpected=$unexpected" >&2
    exit 1
  fi
}

cleanup() {
  # Usage rows outlive a deleted account (the foreign key sets null) and count
  # toward the app-wide spending cap for a day. Remove them first, or a few
  # local runs fill the US$1 cap and the next test is refused.
  db -q -c "delete from public.ai_usage where user_id in ('${TEST_USER_ID}', '${FREE_USER_ID}')
              or user_id::text like '${COLLISION_USER_PREFIX}%'
              or user_id in ('${RESTORE_FROM_ID}', '${RESTORE_TO_ID}')" >/dev/null 2>&1 || true
  db -q -c "delete from public.subscription_transactions
              where original_transaction_id = 'race-restore';
            delete from private.subscription_transfers
              where event_id like 'race-restore-%';
            delete from public.subscription_webhook_events
              where event_id like 'race-restore-%';
            delete from auth.users
              where id in ('${RESTORE_FROM_ID}', '${RESTORE_TO_ID}')" >/dev/null 2>&1 || true
  db -q -c "delete from auth.users where id = '${TEST_USER_ID}'" >/dev/null 2>&1 || true
  db -q -c "delete from auth.users where id = '${FREE_USER_ID}'" >/dev/null 2>&1 || true
  db -q -c "delete from auth.users where id::text like '${COLLISION_USER_PREFIX}%'" \
    >/dev/null 2>&1 || true
  rm -rf "$TEST_OUTPUT_DIR"
}
trap cleanup EXIT

db -q -c "
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
  ) values (
    '${TEST_USER_ID}', '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', null, '', '{}', '{}', now(), now(), true
  );
  insert into public.entitlements (user_id, tier, expires_at)
  values ('${TEST_USER_ID}', 'plus', now() + interval '1 day');
  do \$body\$
  declare usage uuid;
  begin
    usage := public.check_and_record_ai_usage(
      '${TEST_USER_ID}', 'grade', 'claude-opus-5');
    perform public.finalize_ai_usage(usage, 'completed', 100, 100, null);
  end
  \$body\$;
" >/dev/null

# Plus has one weekly grading left. Twelve independent connections race for it.
for i in $(seq 1 12); do
  (
    set +e
    db -Atq -c "select public.check_and_record_ai_usage(
      '${TEST_USER_ID}', 'grade', 'claude-opus-5')" \
      >"$TEST_OUTPUT_DIR/grade-$i" 2>&1
    status=$?
    printf '%s\n' "$status" >"$TEST_OUTPUT_DIR/grade-$i.status"
  ) &
done
wait
assert_race_outcomes grade ALLOWANCE_WEEKLY

GRADE_SUCCESS=$(awk '/^[0-9a-f]{8}-[0-9a-f-]{27}$/{n++} END{print n+0}' \
  "$TEST_OUTPUT_DIR"/grade-*)
GRADE_RESERVED=$(db -Atq -c "select count(*) from public.ai_usage
  where user_id = '${TEST_USER_ID}' and kind = 'grade' and attempt_state = 'reserved'")
if [ "$GRADE_SUCCESS" -ne 1 ] || [ "$GRADE_RESERVED" -ne 1 ]; then
  echo "grading race failed: successes=$GRADE_SUCCESS reserved=$GRADE_RESERVED" >&2
  exit 1
fi

# Free has five AI plans a week. Seed four, two days back -- inside the weekly
# allowance, outside the rate-limit windows -- then race twelve for the last.
db -q -c "
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
  ) values (
    '${FREE_USER_ID}', '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', null, '', '{}', '{}', now(), now(), true
  );
  insert into public.ai_usage (user_id, kind, model, attempt_state,
                               reserved_cost_microusd, created_at)
  select '${FREE_USER_ID}', 'breakdown', 'claude-haiku-4-5', 'completed', 1,
         now() - interval '2 days'
    from generate_series(1, 4);
" >/dev/null

for i in $(seq 1 12); do
  (
    set +e
    db -Atq -c "select public.check_and_record_ai_usage(
      '${FREE_USER_ID}', 'breakdown', 'claude-haiku-4-5')" \
      >"$TEST_OUTPUT_DIR/breakdown-$i" 2>&1
    status=$?
    printf '%s\n' "$status" >"$TEST_OUTPUT_DIR/breakdown-$i.status"
  ) &
done
wait
assert_race_outcomes breakdown ALLOWANCE_WEEKLY

PLAN_RESERVED=$(db -Atq -c "select count(*) from public.ai_usage
  where user_id = '${FREE_USER_ID}' and kind = 'breakdown' and attempt_state = 'reserved'")
if [ "$PLAN_RESERVED" -ne 1 ]; then
  echo "AI plan race failed: reserved=$PLAN_RESERVED" >&2
  exit 1
fi

# Plus has ten active tasks. Seed nine, then race twelve RPC calls for the last.
db -q -c "insert into public.assignments
  (user_id, title, task_type, deadline, estimated_minutes)
  select '${TEST_USER_ID}', 'Seed ' || i, 'essay', now() + interval '7 days', 60
    from generate_series(1, 9) i" >/dev/null

for i in $(seq 1 12); do
  (
    set +e
    db -Atq -c "begin;
      set local role authenticated;
      set local \"request.jwt.claim.sub\" = '${TEST_USER_ID}';
      select public.create_assignment_with_plan(
        'Racer $i', 'essay', now() + interval '7 days', 60,
        '[{\"title\":\"Draft\",\"estimated_minutes\":60}]'::jsonb,
        null, null, null, null, 'normal');
      commit;" >"$TEST_OUTPUT_DIR/task-$i" 2>&1
    status=$?
    printf '%s\n' "$status" >"$TEST_OUTPUT_DIR/task-$i.status"
  ) &
done
wait
assert_race_outcomes task PLAN_TASK_LIMIT_REACHED

TASK_SUCCESS=$(awk '/^[0-9a-f]{8}-[0-9a-f-]{27}$/{n++} END{print n+0}' \
  "$TEST_OUTPUT_DIR"/task-*)
TASK_TOTAL=$(db -Atq -c "select count(*) from public.assignments
  where user_id = '${TEST_USER_ID}' and status = 'active'")
if [ "$TASK_SUCCESS" -ne 1 ] || [ "$TASK_TOTAL" -ne 10 ]; then
  echo "assignment race failed: successes=$TASK_SUCCESS total=$TASK_TOTAL" >&2
  exit 1
fi

# Plus has five saved rubrics. Seed four, then race distinct upserts for one slot.
db -q -c "insert into public.rubrics (user_id, name, source, total_marks)
  select '${TEST_USER_ID}', 'Seed rubric ' || i, 'custom', 10
    from generate_series(1, 4) i" >/dev/null

for i in $(seq 1 12); do
  RUBRIC_ID=$(printf '41000000-0000-4000-8000-%012d' "$i")
  (
    set +e
    db -Atq -c "begin;
      set local role authenticated;
      set local \"request.jwt.claim.sub\" = '${TEST_USER_ID}';
      select public.upsert_rubric(
        '${RUBRIC_ID}', 'Racer $i', 'custom', null, 10,
        '[{\"code\":\"A\",\"name\":\"Quality\",\"marks\":10}]'::jsonb);
      commit;" >"$TEST_OUTPUT_DIR/rubric-$i" 2>&1
    status=$?
    printf '%s\n' "$status" >"$TEST_OUTPUT_DIR/rubric-$i.status"
  ) &
done
wait
assert_race_outcomes rubric RUBRIC_PLAN_LIMIT

RUBRIC_SUCCESS=$(awk '/^[0-9a-f]{8}-[0-9a-f-]{27}$/{n++} END{print n+0}' \
  "$TEST_OUTPUT_DIR"/rubric-*)
RUBRIC_TOTAL=$(db -Atq -c "select count(*) from public.rubrics
  where user_id = '${TEST_USER_ID}'")
if [ "$RUBRIC_SUCCESS" -ne 1 ] || [ "$RUBRIC_TOTAL" -ne 5 ]; then
  echo "rubric race failed: successes=$RUBRIC_SUCCESS total=$RUBRIC_TOTAL" >&2
  exit 1
fi

# A rubric UUID is generated by an untrusted client. Twelve different accounts
# now race the same unused UUID. Exactly one may become its owner; every other
# SECURITY DEFINER call must re-check after the winning transaction commits and
# must not overwrite the winner or replace its criteria.
db -q -c "insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
  )
  select
    ('${COLLISION_USER_PREFIX}' || lpad(i::text, 12, '0'))::uuid,
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', null, '', '{}', '{}', now(), now(), true
  from generate_series(1, 12) i" >/dev/null

for i in $(seq 1 12); do
  COLLISION_USER_ID=$(printf '%s%012d' "$COLLISION_USER_PREFIX" "$i")
  (
    set +e
    db -Atq -c "begin;
      set local role authenticated;
      set local \"request.jwt.claim.sub\" = '${COLLISION_USER_ID}';
      select public.upsert_rubric(
        '${COLLISION_RUBRIC_ID}', 'Owner racer $i', 'custom', null, 10,
        '[{\"code\":\"A\",\"name\":\"Owner criterion $i\",\"marks\":10}]'::jsonb);
      commit;" >"$TEST_OUTPUT_DIR/rubric-owner-$i" 2>&1
    status=$?
    printf '%s\n' "$status" >"$TEST_OUTPUT_DIR/rubric-owner-$i.status"
  ) &
done
wait
assert_race_outcomes rubric-owner RUBRIC_NOT_YOURS

COLLISION_RUBRICS=$(db -Atq -c "select count(*) from public.rubrics
  where id = '${COLLISION_RUBRIC_ID}'")
COLLISION_ITEMS=$(db -Atq -c "select count(*) from public.rubric_items
  where rubric_id = '${COLLISION_RUBRIC_ID}'")
if [ "$COLLISION_RUBRICS" -ne 1 ] || [ "$COLLISION_ITEMS" -ne 1 ]; then
  echo "rubric ownership race failed: rubrics=$COLLISION_RUBRICS items=$COLLISION_ITEMS" >&2
  exit 1
fi

# A restore moves a purchase and its last 30 days of AI use while the same two
# accounts ask for AI and RevenueCat delivers renewals. The restore takes the
# AI gate's locks in the gate's own order, global then accounts; the other
# order deadlocks within a few rounds. Twelve rounds of all four must finish
# with no deadlock and leave the purchase, and Pro, with exactly one account.
db -q -c "
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_anonymous
  )
  select u, '00000000-0000-0000-0000-000000000000',
         'authenticated', 'authenticated', null, '', '{}', '{}', now(), now(), true
    from unnest(array['${RESTORE_FROM_ID}', '${RESTORE_TO_ID}']::uuid[]) u;
  select public.apply_subscription_state(
    'race-restore', '${RESTORE_FROM_ID}', 'race-restore-0',
    'com.felipegutierrez.albus.pro.monthly', 'Production', now(),
    now() + interval '1 month', null, 'race-restore-event-0',
    now() - interval '1 hour');
" >/dev/null

for i in $(seq 1 12); do
  FROM_ID=$RESTORE_FROM_ID
  TO_ID=$RESTORE_TO_ID
  if [ $((i % 2)) -eq 0 ]; then
    FROM_ID=$RESTORE_TO_ID
    TO_ID=$RESTORE_FROM_ID
  fi
  (
    set +e
    db -Atq -c "select public.transfer_subscriptions(
      array['${FROM_ID}']::uuid[], '${TO_ID}', 'race-restore-transfer-$i', now())" \
      >"$TEST_OUTPUT_DIR/restore-transfer-$i" 2>&1
  ) &
  (
    set +e
    db -Atq -c "select public.apply_subscription_state(
      'race-restore', '${FROM_ID}', 'race-restore-$i',
      'com.felipegutierrez.albus.pro.monthly', 'Production', now(),
      now() + interval '1 month' + interval '$i minutes', null,
      'race-restore-event-$i', now() - interval '1 hour' + interval '$i seconds')" \
      >"$TEST_OUTPUT_DIR/restore-renewal-$i" 2>&1
  ) &
  (
    set +e
    db -Atq -c "select public.check_and_record_ai_usage(
      '${FROM_ID}', 'breakdown', 'claude-haiku-4-5')" \
      >"$TEST_OUTPUT_DIR/restore-plan-$i" 2>&1
  ) &
  (
    set +e
    db -Atq -c "select public.check_and_record_ai_usage(
      '${TO_ID}', 'grade', 'claude-opus-5')" \
      >"$TEST_OUTPUT_DIR/restore-grade-$i" 2>&1
  ) &
done
wait

if grep -q deadlock "$TEST_OUTPUT_DIR"/restore-*; then
  echo "restore race deadlocked:" >&2
  grep -l deadlock "$TEST_OUTPUT_DIR"/restore-* >&2
  exit 1
fi
# Refusals from the gate are expected: the accounts change plan mid-race and
# the paid fuse fills. Anything else, including a refused connection, is not.
RESTORE_UNEXPECTED=$(grep -hiE 'error|fatal' "$TEST_OUTPUT_DIR"/restore-* \
  | grep -vE 'ALLOWANCE_|RATE_LIMIT_|GLOBAL_CAPACITY|FAIR_USE|PLAN_UPGRADE|ABUSE_SUSPECTED|VERIFICATION_REQUIRED' \
  || true)
if [ -n "$RESTORE_UNEXPECTED" ]; then
  echo "restore race failed unexpectedly:" >&2
  printf '%s\n' "$RESTORE_UNEXPECTED" >&2
  exit 1
fi
RESTORE_ROWS=$(db -Atq -c "select count(*) from public.subscription_transactions
  where original_transaction_id = 'race-restore'")
RESTORE_PRO=$(db -Atq -c "select count(*) from unnest(
  array['${RESTORE_FROM_ID}', '${RESTORE_TO_ID}']::uuid[]) u
  where public.effective_tier(u) = 'pro'")
RESTORE_OWNER_PRO=$(db -Atq -c "select public.effective_tier(s.user_id)
  from public.subscription_transactions s
  where s.original_transaction_id = 'race-restore'")
if [ "$RESTORE_ROWS" -ne 1 ] || [ "$RESTORE_PRO" -ne 1 ] || [ "$RESTORE_OWNER_PRO" != "pro" ]; then
  echo "restore race failed: rows=$RESTORE_ROWS pro=$RESTORE_PRO owner=$RESTORE_OWNER_PRO" >&2
  exit 1
fi

printf 'concurrency attacks pass: grading 1/12, AI plan 1/12, task 1/12, rubric 1/12, rubric-owner 1/12, restore 0 deadlocks\n'
