-- 외부 연결 없는 빈 검사 DB 전용 합성 자료. 실제 서버에서 실행하지 않는다.
begin;
insert into auth.users values ('10000000-0000-0000-0000-000000000001'), ('10000000-0000-0000-0000-000000000002');
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);
select public.ensure_project('20000000-0000-0000-0000-000000000001', 'migration-control-test');
update private.sync_contract_allowlist set enabled=true where contract_version='0.2.0';

create function pg_temp.control_id(path text) returns uuid language plpgsql as $$
declare h bytea;
begin
  h := extensions.digest(uuid_send('20000000-0000-0000-0000-000000000001'::uuid) || convert_to(path, 'UTF8'), 'sha1');
  h := set_byte(h,6,(get_byte(h,6)&15)|80);
  h := set_byte(h,8,(get_byte(h,8)&63)|128);
  return encode(substring(h,1,16),'hex')::uuid;
end $$;

do $$
declare
  p constant uuid := '20000000-0000-0000-0000-000000000001';
  u constant uuid := '10000000-0000-0000-0000-000000000001';
  device constant uuid := '30000000-0000-0000-0000-000000000001';
  regular constant uuid := '40000000-0000-0000-0000-000000000001';
  path text; r jsonb; fixed boolean := current_setting('test.expect_fixed')::boolean;
  before_documents jsonb; before_versions jsonb; d public.documents%rowtype;
begin
  foreach path in array array['__antigravity__/tree-order.json','__antigravity__/trash-purge.json'] loop
    perform public.commit_document(pg_temp.control_id(path),p,0,gen_random_uuid(),device,path,'{}',false,null);
  end loop;
  perform public.commit_document(regular,p,0,gen_random_uuid(),device,'draft.txt','synthetic',false,null);
  update public.documents set name='draft.txt',structure_revision=1 where document_id=regular;
  insert into public.folders(folder_id,project_id,name,revision,created_by,updated_by)
    values ('50000000-0000-0000-0000-000000000001',p,'folder',1,u,u);
  select jsonb_agg(to_jsonb(x) order by x.document_id) into before_documents
    from public.documents x where x.project_id=p and x.document_id<>regular;
  select jsonb_agg(to_jsonb(x) order by x.document_id,x.revision) into before_versions
    from public.document_versions x where x.project_id=p;
  r := public.begin_project_sync_migration(p,device,'416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670');
  if r->>'status'<>'migrating' then raise exception 'begin failed'; end if;
  r := public.validate_project_sync_migration(p);
  if not fixed then
    if r->>'valid'<>'false' or not (r->'issues' @> '[{"code":"STORAGE_NAME_INVALID","count":2}]') then
      raise exception 'original failure not reproduced: %',r;
    end if;
    raise notice 'PASS original: two valid internal documents block migration';
    return;
  end if;
  if r->>'valid'<>'true' then raise exception 'valid control documents rejected: %',r; end if;
  select * into d from public.documents where document_id=pg_temp.control_id('__antigravity__/tree-order.json');
  d.document_id:=gen_random_uuid();
  if private.is_contract_migration_control_document(d) then raise exception 'wrong UUID accepted'; end if;
  d.document_id:=pg_temp.control_id('__antigravity__/tree-order.json');
  d.project_id:=gen_random_uuid();
  if private.is_contract_migration_control_document(d) then raise exception 'wrong project accepted'; end if;
  update public.documents set name=null where document_id=regular;
  r:=public.validate_project_sync_migration(p);
  if r->>'valid'<>'false' or not (r->'issues' @> '[{"code":"STORAGE_NAME_INVALID","count":1}]') then raise exception 'unnamed manuscript accepted'; end if;
  update public.documents set name='draft.txt' where document_id=regular;
  update public.documents set name='spoof' where document_id=pg_temp.control_id('__antigravity__/tree-order.json');
  r:=public.validate_project_sync_migration(p);
  if r->>'valid'<>'false' or not (r->'issues' @> '[{"code":"INVALID_CONTROL_DOCUMENT","count":1}]') then raise exception 'control metadata spoof accepted'; end if;
  update public.documents set name=null,relative_path='__antigravity__/unknown.json' where document_id=pg_temp.control_id('__antigravity__/tree-order.json');
  r:=public.validate_project_sync_migration(p);
  if r->>'valid'<>'false' or not (r->'issues' @> '[{"code":"INVALID_CONTROL_DOCUMENT","count":1}]') then raise exception 'unknown control path accepted'; end if;
  update public.documents set relative_path='__antigravity__/tree-order.json' where document_id=pg_temp.control_id('__antigravity__/tree-order.json');
  perform set_config('request.jwt.claim.sub','',true);
  begin
    perform public.validate_project_sync_migration(p);
    raise exception 'missing auth accepted';
  exception when raise_exception then
    if sqlerrm<>'AUTH_REQUIRED' then raise; end if;
  end;
  perform set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000002',true);
  begin
    perform public.complete_project_sync_migration(p,device,1);
    raise exception 'nonmember accepted';
  exception when raise_exception then
    if sqlerrm<>'FORBIDDEN' then raise; end if;
  end;
  perform set_config('request.jwt.claim.sub',u::text,true);
  begin
    perform public.complete_project_sync_migration(p,gen_random_uuid(),1);
    raise exception 'wrong writer accepted';
  exception when raise_exception then
    if sqlerrm<>'MIGRATION_LOCKED' then raise; end if;
  end;
  r:=public.complete_project_sync_migration(p,device,1);
  if r->>'status'<>'id_based' then raise exception 'completion failed: %',r; end if;
  if (select jsonb_agg(to_jsonb(x) order by x.document_id) from public.documents x where x.project_id=p and x.document_id<>regular) is distinct from before_documents then raise exception 'control data changed'; end if;
  if (select jsonb_agg(to_jsonb(x) order by x.document_id,x.revision) from public.document_versions x where x.project_id=p) is distinct from before_versions then raise exception 'history changed'; end if;
  if (select storage_name_key from public.documents where document_id=regular) is null then raise exception 'manuscript key missing'; end if;
  if (select storage_name_key from public.folders where project_id=p) is null then raise exception 'folder key missing'; end if;
  if has_function_privilege('anon','private.is_contract_migration_control_document(public.documents)','execute')
    or has_function_privilege('authenticated','private.is_contract_migration_control_document(public.documents)','execute') then raise exception 'helper publicly executable'; end if;
  raise notice 'PASS fixed: controls preserved; manuscript validation, identity, authorization and completion checked';
end $$;
rollback;
