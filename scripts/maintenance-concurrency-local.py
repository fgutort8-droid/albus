#!/usr/bin/env python3
"""Exercise maintenance serialization using only an explicitly named audit DB."""
import os
import select
import subprocess
import time

project = os.environ.get('ALBUS_AUDIT_PROJECT', '')
if not project.startswith('albus-audit-') or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-' for c in project):
    raise SystemExit('Set ALBUS_AUDIT_PROJECT to an isolated albus-audit-* project')
command = ['docker', 'exec', '-i', 'supabase_db_' + project, 'psql', '-U', 'postgres', '-d', 'postgres', '-X', '-Atq', '-v', 'ON_ERROR_STOP=1']
uid = 'a9300000-0000-4000-8000-000000000001'

def sql(text):
    return subprocess.run(command, input=text, text=True, capture_output=True, check=True, timeout=15).stdout.strip()

def seed():
    sql(f"insert into auth.users(id,instance_id,aud,role,encrypted_password,raw_app_meta_data,raw_user_meta_data,created_at,updated_at,is_anonymous) values('{uid}','00000000-0000-0000-0000-000000000000','authenticated','authenticated','','{{}}','{{}}',now()-interval '31 days',now()-interval '31 days',true)")

def held(statement):
    p = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    p.stdin.write('begin; set local statement_timeout=\'10s\'; ' + statement + "; select 'ready';\n")
    p.stdin.flush()
    if not select.select([p.stdout], [], [], 10)[0] or p.stdout.readline().strip() != 'ready':
        p.kill()
        raise AssertionError('writer did not acquire its lock')
    return p

def finish(p):
    p.stdin.write('rollback;\n')
    p.stdin.close()
    p.wait(timeout=12)
    if p.returncode:
        raise AssertionError(p.stderr.read())

cases = {
    'session refresh': f"update auth.sessions set updated_at=now() where user_id='{uid}'",
    'profile update': f"update public.profiles set display_name='Studying' where id='{uid}'",
    'sign-in update': f"update auth.users set last_sign_in_at=now() where id='{uid}'",
    'explicit deletion': f"delete from auth.users where id='{uid}'",
    'content insert': f"insert into public.rubrics(user_id,name,source,total_marks) values('{uid}','Study','custom',10)",
    'subscription owner operation': f"do $$ begin perform pg_advisory_xact_lock(hashtextextended('albus:subscription-owner:{uid}',0)); end $$",
}
for name, statement in cases.items():
    seed()
    if name == 'session refresh':
        sql(f"insert into auth.sessions(id,user_id,created_at,updated_at) values(gen_random_uuid(),'{uid}',now()-interval '31 days',now()-interval '31 days')")
    p = None
    try:
        p = held(statement)
        started = time.monotonic()
        assert sql('select public.reap_abandoned_anonymous_users(30)') == '0', name
        assert time.monotonic()-started < 5, name + ' should yield, not wait'
        finish(p)
        p = None
        assert sql(f"select count(*) from auth.users where id='{uid}'") == '1', name
        print(name + ': retained without waiting')
    finally:
        if p is not None:
            p.kill(); p.wait()
        sql(f"delete from auth.users where id='{uid}'")
# Hold a transaction lock before the transfer reaches its owner locks.
seed()
source = 'a9300000-0000-4000-8000-000000000002'
blocker = transfer = None
try:
    sql(f"insert into auth.users(id,instance_id,aud,role,created_at,updated_at,is_anonymous) values('{source}','00000000-0000-0000-0000-000000000000','authenticated','authenticated',now(),now(),true)")
    sql(f"insert into public.subscription_transactions(original_transaction_id,user_id,environment) values('maintenance-race-transfer','{source}','Production')")
    blocker = held("do $$ begin perform pg_advisory_xact_lock(hashtextextended('albus:subscription:maintenance-race-transfer',0)); end $$")
    transfer = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    transfer.stdin.write(f"set application_name='albus-maintenance-transfer-test'; begin; set local statement_timeout='10s'; select public.transfer_subscriptions(array['{source}']::uuid[],'{uid}','maintenance-transfer-event',now()); rollback;\n")
    transfer.stdin.close()
    for _ in range(50):
        if sql("select count(*) from pg_stat_activity where application_name='albus-maintenance-transfer-test' and wait_event='advisory'") == '1':
            break
        time.sleep(.05)
    else:
        raise AssertionError('transfer did not reach the transaction lock')
    assert sql('select public.reap_abandoned_anonymous_users(30)') == '0', 'in-flight transfer destination'
    finish(blocker); blocker = None
    transfer.wait(timeout=12)
    assert transfer.returncode == 0, transfer.stderr.read()
    assert 'transferred' in transfer.stdout.read()
    transfer = None
    assert sql(f"select count(*) from auth.users where id='{uid}'") == '1'
    print('transfer waiting before owner lock: destination retained')
finally:
    for process in (transfer, blocker):
        if process is not None:
            process.kill(); process.wait()
    sql("delete from public.subscription_transactions where original_transaction_id='maintenance-race-transfer'")
    sql(f"delete from auth.users where id in ('{uid}','{source}')")
print('maintenance concurrency checks passed')
