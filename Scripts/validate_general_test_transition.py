"""외부 연결 없는 임시 DB에서 전환 준비 SQL의 성공·거절·롤백을 검사한다."""
import copy
import json
from pathlib import Path
import subprocess
import time
import uuid
from prepare_general_test_transition import prepare, SQL

root = Path(__file__).resolve().parents[1]
out = root / 'build/ipad-general-integration-20260910'
container = 'writerpad-transition-test-' + uuid.uuid4().hex[:10]
log = []


def run(args, **kwargs):
    r = subprocess.run(args, capture_output=True, text=True, **kwargs)
    log.append(r.stdout + r.stderr)
    if r.returncode:
        raise RuntimeError((r.stdout + r.stderr)[-3000:])
    return r.stdout


def sql(query, failure=None):
    args = ['docker', 'exec', '-i', container, 'psql', '-h', '/tmp', '-U', 'postgres',
            '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-X', '-qAt']
    r = subprocess.run(args, input=query, capture_output=True, text=True)
    log.append(r.stdout + r.stderr)
    if failure:
        assert r.returncode and failure in r.stderr, r.stdout + r.stderr
    elif r.returncode:
        raise RuntimeError((r.stdout + r.stderr)[-3000:])
    return r.stdout.strip()


try:
    run(['docker','run','-d','--name',container,'--network','none','--user','postgres',
         '--entrypoint','sh','public.ecr.aws/supabase/postgres:17.6.1.155','-c',
         'initdb -D /tmp/transition-db -A trust >/tmp/init.log && exec postgres -D /tmp/transition-db -k /tmp -c listen_addresses='])
    for _ in range(40):
        if subprocess.run(['docker','exec',container,'pg_isready','-h','/tmp'],capture_output=True).returncode == 0:
            break
        time.sleep(.5)
    else:
        raise RuntimeError('isolated DB startup timed out')
    sql("CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role; CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid PRIMARY KEY); CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;")
    for name in ['20260811000000_operational_v2_schema_baseline_snapshot.sql',
                 '20260811010000_sync_contract_0_1_0_foundation.sql',
                 '20260811020000_sync_contract_0_1_0_rpcs.sql',
                 '20260910053721_general_contract_trash_purge.sql',
                 '20260910072310_contract_migration_control_documents.sql']:
        sql((root/'supabase/migrations'/name).read_text())
    p = uuid.UUID('20000000-0000-0000-0000-000000000042')
    owner = '10000000-0000-0000-0000-000000000042'
    main = str(uuid.uuid5(p,'main'))
    folders = [{'id':main,'parent':None,'name':'Main','revision':1,'deleted':False}]
    folders += [{'id':str(uuid.uuid5(p,'folder-'+str(i))),'parent':main,'name':'Folder'+str(i),'revision':1,'deleted':False} for i in range(10)]
    content = json.dumps({'version':1,'tree_order':{'<root>':[f['name'] for f in folders[1:]]}}, separators=(',',':'))
    control = {'id':str(uuid.uuid5(p,'__antigravity__/tree-order.json')),'path':'__antigravity__/tree-order.json','content':content,'revision':1}
    plan, prepared = prepare(str(p),{'folders':folders,'control':[control]},str(uuid.uuid4()),str(uuid.uuid4()))
    sql(f"insert into auth.users values ('{owner}'); select set_config('request.jwt.claim.sub','{owner}',false); select public.ensure_project('{p}','synthetic target'); select public.ensure_project('20000000-0000-0000-0000-000000000043','untouched'); update private.sync_contract_allowlist set enabled=true where contract_version='0.2.0';")
    for f in folders:
        parent = 'NULL' if f['parent'] is None else "'"+f['parent']+"'"
        sql(f"insert into public.folders(folder_id,project_id,parent_folder_id,name,revision,created_by,updated_by) values ('{f['id']}','{p}',{parent},'{f['name']}',1,'{owner}','{owner}');")
    sql(f"select set_config('request.jwt.claim.sub','{owner}',false); select public.commit_document('{control['id']}','{p}',0,gen_random_uuid(),gen_random_uuid(),'{control['path']}','{content}',false,null);")
    def state():
        return sql("select jsonb_build_object('settings',(select jsonb_agg(to_jsonb(s)) from public.project_sync_settings s),'migrations',(select jsonb_agg(to_jsonb(s)) from public.project_sync_migrations s),'orders',(select jsonb_agg(to_jsonb(s) order by tree_order_id) from public.tree_orders s),'batches',(select jsonb_agg(to_jsonb(s)) from public.sync_batches s),'documents',(select jsonb_agg(to_jsonb(s)) from public.documents s));")
    sql(f"update public.folders set revision=2 where folder_id='{main}';")
    before = state()
    sql(prepared, failure='TEST_FOLDER_BASELINE_CHANGED')
    assert state() == before
    sql(f"update public.folders set revision=1 where folder_id='{main}';")
    bad = copy.deepcopy(plan)
    bad['orders'][1]['children'][0] = str(uuid.uuid4())
    before = state()
    sql(SQL.replace('__PLAN__',json.dumps(bad)), failure='ORDER_SEED_FAILED')
    assert state() == before, 'failed order RPC left partial migration'
    sql(prepared)
    assert sql(f"select project_sync_mode||':'||migration_epoch from public.project_sync_settings where project_id='{p}';") == 'ID_BASED:1'
    assert sql('select count(*) from public.tree_orders;') == '12'
    assert sql("select count(*) from public.project_sync_settings where project_id='20000000-0000-0000-0000-000000000043';") == '0'
    before = state()
    sql(prepared, failure='TEST_PROJECT_NOT_FRESH_LEGACY')
    assert state() == before, 'second execution changed completed project'
    result = {'result':'Passed','isolated':True,'server_changes':False,
              'checks':['baseline drift abort','mid-transition RPC failure full rollback','12 exact UUID orders',
                        'ID_BASED epoch 1 completion','legacy control/history preservation',
                        'other project unchanged','repeated execution no mutation']}
    (out/'test-transition-validation.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2),flush=True)
finally:
    subprocess.run(['docker','rm','-f','-v',container],capture_output=True)
    (out/'test-transition-validation.log').write_text('\n'.join(log))
