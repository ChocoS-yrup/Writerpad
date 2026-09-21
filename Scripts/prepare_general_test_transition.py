"""합성 시험 작품의 관측된 초기 구조만 대상으로 전환 SQL을 준비한다. 실행하지 않는다."""
import hashlib
import json
import uuid

CONTRACT = '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670'


def prepare(project_id, baseline, writer_id, batch_id):
    project = uuid.UUID(project_id)
    folders = sorted(baseline['folders'], key=lambda f: f['id'])
    roots = [f for f in folders if f['parent'] is None]
    assert len(roots) == 1 and len(folders) == 11
    root = roots[0]
    children = [f for f in folders if f['parent'] == root['id']]
    assert len(children) == 10 and all(not f['deleted'] and f['revision'] == 1 for f in folders)
    assert len({f['id'] for f in folders}) == 11
    control, = baseline['control']
    assert control['path'] == '__antigravity__/tree-order.json'
    assert control['id'] == str(uuid.uuid5(project, control['path'])) and control['revision'] == 1
    names = json.loads(control['content'])['tree_order']['<root>']
    by_name = {f['name']: f['id'] for f in children}
    assert len(by_name) == 10 and len(names) == 10 and set(names) == set(by_name)
    orders = [{'parent': None, 'children': [root['id']]},
              {'parent': root['id'], 'children': [by_name[n] for n in names]}]
    orders += [{'parent': f['id'], 'children': []} for f in sorted(children, key=lambda f: f['id'])]
    for order in orders:
        order['id'] = str(uuid.uuid5(project, 'tree-order:' + (order['parent'] or 'root')))
        order['operation_id'] = str(uuid.uuid5(uuid.UUID(batch_id), order['id']))
    plan = {'project_id': str(project), 'folders': folders, 'control_id': control['id'],
            'control_sha256': hashlib.sha256(control['content'].encode()).hexdigest(),
            'writer_id': str(uuid.UUID(writer_id)), 'batch_id': str(uuid.UUID(batch_id)),
            'contract_sha256': CONTRACT, 'orders': orders}
    payload = json.dumps(plan, ensure_ascii=False, sort_keys=True)
    assert '$plan$' not in payload and '$transition$' not in payload
    return plan, SQL.replace('__PLAN__', payload)


SQL = r"""-- 승인 전 실행 금지. 서버 관리 경로의 시험 작품 전환이며 앱 송신 시험이 아니다.
begin;
do $transition$
declare
  p jsonb := $plan$__PLAN__$plan$::jsonb;
  project uuid := (p->>'project_id')::uuid;
  owner uuid; actual jsonb; original_versions jsonb; r jsonb;
  entry jsonb; intent jsonb; intents jsonb := '[]'::jsonb; meta jsonb; caps text[];
  seq integer := 0;
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('project:' || project::text,0));
  select owner_id into owner from public.projects where project_id=project and trashed_at is null for update;
  if not found then raise exception 'TEST_PROJECT_NOT_ACTIVE'; end if;
  if exists(select 1 from public.project_sync_settings where project_id=project)
     or exists(select 1 from public.project_sync_migrations where project_id=project)
     or exists(select 1 from public.tree_orders where project_id=project) then
    raise exception 'TEST_PROJECT_NOT_FRESH_LEGACY';
  end if;
  select jsonb_agg(jsonb_build_object('id',folder_id,'parent',parent_folder_id,'name',name,'revision',revision,'deleted',is_deleted) order by folder_id)
    into actual from public.folders where project_id=project;
  if actual is distinct from p->'folders' then raise exception 'TEST_FOLDER_BASELINE_CHANGED'; end if;
  if (select count(*) from public.documents where project_id=project) <> 1
     or not exists(select 1 from public.documents d where d.project_id=project
       and d.document_id=(p->>'control_id')::uuid and d.revision=1 and not d.is_deleted
       and private.is_contract_migration_control_document(d)
       and encode(extensions.digest(convert_to(d.content,'UTF8'),'sha256'),'hex')=p->>'control_sha256') then
    raise exception 'TEST_DOCUMENT_BASELINE_CHANGED';
  end if;
  select jsonb_agg(to_jsonb(v) order by v.version_id) into original_versions
    from public.document_versions v where v.project_id=project;
  -- 관리 실행임을 별도 기기/빌드 식별자로 남긴다. Windows나 iPad 요청으로 표시하지 않는다.
  perform set_config('request.jwt.claim.sub',owner::text,true);
  r := public.begin_project_sync_migration(project,(p->>'writer_id')::uuid,p->>'contract_sha256');
  if r->>'status'<>'migrating' or (r->>'migration_epoch')::integer<>1 then raise exception 'BEGIN_FAILED'; end if;
  select allowed_client_capabilities into caps from private.sync_contract_allowlist
    where canonical_contract_sha256=p->>'contract_sha256' and contract_version='0.2.0' and enabled;
  if not found then raise exception 'CONTRACT_NOT_ENABLED'; end if;
  for entry in select value from jsonb_array_elements(p->'orders') loop
    seq:=seq+1;
    intent:=jsonb_build_object('sequence',seq,'batch_id',p->>'batch_id','operation_id',entry->>'operation_id',
      'entity_kind','tree_order','entity_id',entry->>'id','intent_kind','reorder','base_revision',0,
      'payload',jsonb_build_object('parent_folder_id',entry->'parent','children',entry->'children'));
    intent:=intent || jsonb_build_object('payload_sha256',private.jsonb_rfc8785_sha256(intent->'payload'));
    intents:=intents || jsonb_build_array(intent);
  end loop;
  meta:=jsonb_build_object('batch_id',p->>'batch_id','writer_device_id',p->>'writer_id',
    'client_build_id','staging-admin-test-transition-20260910','sync_protocol_version',3,
    'contract_version','0.2.0','canonical_contract_sha256',p->>'contract_sha256',
    'client_capabilities',to_jsonb(caps),'batch_payload_sha256',private.jsonb_rfc8785_sha256(intents));
  r:=public.atomic_structure_commit(jsonb_build_object('kind','atomic_structure_commit_request',
    'project_id',project,'project_sync_mode','MIGRATING','migration_epoch',1,'batch',meta,'ordered_intents',intents));
  if r->>'status'<>'committed' or r->>'applied'<>'true' then raise exception 'ORDER_SEED_FAILED: %',r; end if;
  r:=public.complete_project_sync_migration(project,(p->>'writer_id')::uuid,1);
  if r->>'status'<>'id_based' then raise exception 'COMPLETE_FAILED: %',r; end if;
  if (select count(*) from public.tree_orders where project_id=project) <> 12 then raise exception 'ORDER_COUNT_MISMATCH'; end if;
  for entry in select value from jsonb_array_elements(p->'orders') loop
    if not exists(select 1 from public.tree_orders t where t.project_id=project and t.tree_order_id=(entry->>'id')::uuid
      and t.parent_folder_id is not distinct from (entry->>'parent')::uuid
      and to_jsonb(t.children)=entry->'children' and t.revision=1) then raise exception 'ORDER_CONTENT_MISMATCH'; end if;
  end loop;
  if (select jsonb_agg(to_jsonb(v) order by v.version_id) from public.document_versions v where v.project_id=project)
      is distinct from original_versions then raise exception 'LEGACY_HISTORY_CHANGED'; end if;
  if not exists(select 1 from public.documents d where d.project_id=project and d.document_id=(p->>'control_id')::uuid
      and d.revision=1 and private.is_contract_migration_control_document(d)
      and encode(extensions.digest(convert_to(d.content,'UTF8'),'sha256'),'hex')=p->>'control_sha256') then
    raise exception 'LEGACY_CONTROL_CHANGED';
  end if;
end;
$transition$;
commit;
"""
