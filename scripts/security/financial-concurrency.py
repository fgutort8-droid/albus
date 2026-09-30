#!/usr/bin/env python3
"""Multi-connection durable acceptance, transaction rollback and processing tests."""
import concurrent.futures,json,os,re,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
PROJECT=re.search(r'^project_id = "([^"]+)"',(ROOT/'supabase/config.toml').read_text(),re.M).group(1)
# Local Supabase only (docker exec); never a remote database.
CONTAINER=os.environ.get('ALBUS_DB_CONTAINER','supabase_db_'+PROJECT)

def check(condition,message):
    if not condition:raise SystemExit('FAIL: '+message)

def sql(source):
    result=subprocess.run(['docker','exec','-i',CONTAINER,'psql','-U','postgres','-d','postgres','-X','-Atq','-v','ON_ERROR_STOP=1'],
                          input=source,text=True,capture_output=True)
    if result.returncode:raise RuntimeError('Financial concurrency SQL failed: '+result.stderr)
    return result.stdout.strip()

user='f8000000-0000-4000-8000-000000000001'
payload={'operation':'subscription','subscription':{'p_original_transaction_id':'financial-race',
    'p_user_id':user,'p_latest_transaction_id':'financial-race-tx','p_product_id':'com.felipegutierrez.albus.plus.monthly',
    'p_environment':'Production','p_purchase_date':'2026-09-30T00:00:00Z','p_expires_at':'2030-01-01T00:00:00Z',
    'p_revoked_at':None,'p_event_id':'financial-race-event','p_event_at':'2026-09-30T00:00:00Z',
    'p_store':'APP_STORE','p_app_id':'financial-race-app'}}
scheduled=sql("select active from cron.job where jobname='albus-financial-drain';")=='t'
sql("select cron.alter_job(jobid, active:=false) from cron.job where jobname='albus-financial-drain';")
try:
    sql(f"insert into auth.users(id,instance_id,aud,role,encrypted_password,raw_app_meta_data,raw_user_meta_data,created_at,updated_at,is_anonymous) values ('{user}','00000000-0000-0000-0000-000000000000','authenticated','authenticated','','{{}}','{{}}',now(),now(),false) on conflict do nothing;")
    query="select public.enqueue_revenuecat_event('financial-race-app','financial-race-event',$event$"+json.dumps(payload)+"$event$::jsonb);"
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        identifiers=list(pool.map(lambda _:sql(query),range(12)))
    check(len(set(identifiers))==1,'Duplicate acceptance created more than one event')
    identifier=identifiers[0]
    sql(f"begin;select public.process_financial_event('{identifier}');rollback;")
    check(sql(f"select state from private.financial_inbox where id='{identifier}';")=='pending','Rolled-back processing lost durable work')
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        results=list(pool.map(lambda _:sql(f"select public.process_financial_event('{identifier}');"),range(12)))
    check(set(results)=={'active_plus'},'Concurrent processing returned '+repr(set(results)))
    check(sql(f"select attempts from private.financial_inbox where id='{identifier}';")=='1','Concurrent processing made more than one attempt')
    check(sql(f"select count(*) from private.financial_audit where event_ref='{identifier}' and action='provider_event.processed';")=='1','Concurrent processing wrote more than one audit record')
    print('PASS: 12 acceptors -> one inbox row; rollback preserves pending work; 12 processors -> one effect and audit record.')
finally:
    if scheduled:sql("select cron.alter_job(jobid, active:=true) from cron.job where jobname='albus-financial-drain';")
    # Local fixture only; immutable audit evidence remains until test DB cleanup.
    sql(f"delete from public.subscription_transactions where original_transaction_id='financial-race';delete from private.financial_inbox where event_id='financial-race-event';delete from auth.users where id='{user}';")
