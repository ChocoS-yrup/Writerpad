\set ON_ERROR_STOP on
begin;
set local statement_timeout = '30s';
do $$ begin
  if current_database()<>'writerpad_stage7' or current_user<>'postgres' then raise exception 'TRANSITION_FIXTURE_SCOPE'; end if;
end $$;
insert into auth.users(id) values ('97000000-0000-4000-8000-000000000001'),('97000000-0000-4000-8000-000000000002');
update private.sync_contract_allowlist set enabled=true where canonical_contract_sha256='416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670';

create function pg_temp.transition_request(p uuid,d uuid,payload jsonb,
  target text default '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670') returns jsonb
language plpgsql as $$
declare b uuid:=gen_random_uuid(); i jsonb; caps text[]; version text;
begin
  select allowed_client_capabilities,contract_version into caps,version from private.sync_contract_allowlist
    where canonical_contract_sha256=target;
  i:=jsonb_build_array(jsonb_build_object('sequence',1,'operation_id',gen_random_uuid(),'batch_id',b,
    'entity_kind','project','entity_id',p,'intent_kind','migrate','base_revision',0,
    'payload',payload,'payload_sha256',private.jsonb_rfc8785_sha256(payload)));
  return jsonb_build_object('kind','atomic_structure_commit_request','project_id',p,
    'project_sync_mode','MIGRATING','migration_epoch',1,'ordered_intents',i,
    'batch',jsonb_build_object('batch_id',b,'writer_device_id',d,'client_build_id','transition-ci',
      'sync_protocol_version',3,'contract_version',version,'client_capabilities',to_jsonb(caps),
      'canonical_contract_sha256',target,
      'batch_payload_sha256',private.jsonb_rfc8785_sha256(i)));
end $$;

create function pg_temp.transition_preserved(p uuid) returns jsonb language sql as $$
  select jsonb_build_object('documents',(select jsonb_agg(to_jsonb(d)-array['name','parent_folder_id','storage_name_key','structure_revision','updated_at','updated_by'] order by document_id)
    from public.documents d where project_id=p),'versions',(select jsonb_agg(to_jsonb(v) order by version_id) from public.document_versions v where project_id=p),
    'controls',(select jsonb_agg(to_jsonb(d) order by document_id) from public.documents d where project_id=p and private.is_contract_migration_control_document(d)));
$$;

do $cases$
declare u uuid:='97000000-0000-4000-8000-000000000001'; other_user uuid:='97000000-0000-4000-8000-000000000002';
  p uuid; f uuid; doc uuid; device uuid; request jsonb; changed jsonb; plan jsonb; r jsonb; before_rows jsonb;
  c text; expected text; saved_error text; hash bytea; control uuid; before_metadata jsonb;
begin
  foreach c in array array['ordinary','empty','tombstone','legacy_order','stale_baseline','collision','missing_parent','partial_metadata','wrong_device','editor','wrong_profile','response_loss'] loop
    p:=gen_random_uuid(); f:=gen_random_uuid(); doc:=gen_random_uuid(); device:=gen_random_uuid(); expected:=null;
    perform set_config('request.jwt.claim.sub',u::text,true);
    insert into public.projects(project_id,owner_id,name) values(p,u,'transition synthetic');
    insert into public.project_members(project_id,user_id,role) values(p,u,'owner'),(p,other_user,'editor');
    insert into public.folders(folder_id,project_id,parent_folder_id,name,revision,created_by,updated_by)
      values(f,p,null,'메인',1,u,u);
    if c<>'empty' then
      set local role authenticated;
      perform public.commit_document(doc,p,0,gen_random_uuid(),device,'메인/chapter.txt','unchanged body',false,null);
      reset role;
      update public.documents set updated_at=now()-interval '1 day' where document_id=doc;
    end if;
    if c='tombstone' then update public.documents set is_deleted=true,deleted_at=now() where document_id=doc; end if;
    if c='partial_metadata' then update public.documents set name='chapter.txt' where document_id=doc; expected:='INVARIANT_VIOLATION'; end if;
    if c='missing_parent' then update public.documents set relative_path='missing/chapter.txt' where document_id=doc; expected:='FOLDER_NOT_FOUND'; end if;
    if c='legacy_order' then
      hash:=extensions.digest(uuid_send(p)||convert_to('__antigravity__/tree-order.json','UTF8'),'sha1');
      hash:=set_byte(hash,6,(get_byte(hash,6)&15)|80); hash:=set_byte(hash,8,(get_byte(hash,8)&63)|128);
      control:=encode(substring(hash,1,16),'hex')::uuid;
      set local role authenticated;
      perform public.commit_document(control,p,0,gen_random_uuid(),device,'__antigravity__/tree-order.json',
        '{"tree_order":{"<root>":["chapter.txt"]}}',false,null);
      reset role;
    end if;
    begin
      set local role authenticated;
      plan:=public.get_project_sync_transition_plan(p);
      reset role;
      if expected is not null then raise exception using errcode='XX001',message='preflight accepted '||c; end if;
    exception when sqlstate 'P0001' then
      get stacked diagnostics saved_error=message_text;
      reset role;
      if saved_error is distinct from expected then raise exception 'wrong preflight error %: %',c,saved_error; end if;
      if exists(select 1 from public.project_sync_settings where project_id=p) then raise exception 'PREFLIGHT_WROTE'; end if;
      continue;
    end;
    request:=pg_temp.transition_request(p,device,plan->'payload');
    if c='stale_baseline' then update public.documents set revision=revision+1 where document_id=doc; expected:='TRANSITION_BASELINE_CHANGED'; end if;
    if c='collision' then
      insert into public.folders(folder_id,project_id,parent_folder_id,name,revision,created_by,updated_by)
        values(gen_random_uuid(),p,f,'chapter.txt',1,u,u);
      request:=pg_temp.transition_request(p,device,private.project_transition_payload(p));
      expected:='TRANSITION_PREPARATION_FAILED';
    end if;
    if c='wrong_device' then
      perform public.begin_project_sync_migration(p,gen_random_uuid(),'416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670');
      expected:='TRANSITION_PREPARATION_FAILED';
    end if;
    if c='editor' then perform set_config('request.jwt.claim.sub',other_user::text,true); expected:='FORBIDDEN'; end if;
    if c='wrong_profile' then request:=jsonb_set(request,'{ordered_intents,0,payload,profile_sha256}','"wrong"'); expected:='INVALID_ARGUMENT'; end if;
    before_rows:=pg_temp.transition_preserved(p);
    select jsonb_build_object('documents',(select jsonb_agg(to_jsonb(d) order by document_id) from public.documents d where project_id=p),
      'orders',(select jsonb_agg(to_jsonb(t) order by tree_order_id) from public.tree_orders t where project_id=p)) into before_metadata;
    begin
      set local role authenticated;
      r:=public.prepare_project_sync_transition(request);
      reset role;
      if expected is not null then raise exception using errcode='XX001',message='prepare accepted '||c; end if;
    exception when sqlstate 'P0001' then
      get stacked diagnostics saved_error=message_text;
      reset role;
      if saved_error is distinct from expected then raise exception 'wrong prepare error %: %',c,saved_error; end if;
      if pg_temp.transition_preserved(p) is distinct from before_rows then raise exception 'FAILED_PREPARE_MUTATED_CONTENT'; end if;
      if (select jsonb_build_object('documents',(select jsonb_agg(to_jsonb(d) order by document_id) from public.documents d where project_id=p),
        'orders',(select jsonb_agg(to_jsonb(t) order by tree_order_id) from public.tree_orders t where project_id=p)))
        is distinct from before_metadata then raise exception 'FAILED_PREPARE_MUTATED_STRUCTURE'; end if;
      if c<>'wrong_device' and exists(select 1 from public.project_sync_settings where project_id=p) then raise exception 'FAILED_PREPARE_LEFT_MIGRATING'; end if;
      if exists(select 1 from public.sync_batches where project_id=p) then raise exception 'FAILED_PREPARE_LEFT_LEDGER'; end if;
      continue;
    end;
    if r->>'applied'<>'true' or pg_temp.transition_preserved(p) is distinct from before_rows then raise exception 'PRESERVATION_FAILED %',c; end if;
    if (select project_sync_mode from public.project_sync_settings where project_id=p)<>'MIGRATING' then raise exception 'AUTO_COMPLETED'; end if;
    if c<>'empty' and not exists(select 1 from public.documents where document_id=doc and name='chapter.txt' and parent_folder_id=f and structure_revision=1) then raise exception 'NOT_INITIALIZED'; end if;
    if c<>'empty' and not exists(select 1 from public.documents where document_id=doc and updated_at=transaction_timestamp() and updated_by=u) then raise exception 'STRUCTURE_CHANGE_NOT_MARKED'; end if;
    if c='legacy_order' and not exists(select 1 from public.tree_orders where project_id=p and parent_folder_id=f and children=array[doc]) then raise exception 'ORDER_LOST'; end if;
    if c='ordinary' then
      changed:=jsonb_set(request,'{batch,client_build_id}','"different-build"');
      begin
        set local role authenticated;
        perform public.prepare_project_sync_transition(changed);
        reset role;
        raise exception using errcode='XX001',message='BATCH_REUSE_ACCEPTED';
      exception when sqlstate 'P0001' then
        get stacked diagnostics saved_error=pg_exception_detail;
        reset role;
        if saved_error is null or position('BATCH_ID_REUSED' in saved_error)=0 then raise exception 'WRONG_BATCH_REUSE_ERROR'; end if;
      end;
      changed:=pg_temp.transition_request(p,device,private.project_transition_payload(p));
      changed:=jsonb_set(changed,'{ordered_intents,0,operation_id}',request#>'{ordered_intents,0,operation_id}');
      changed:=jsonb_set(changed,'{batch,batch_payload_sha256}',to_jsonb(private.jsonb_rfc8785_sha256(changed->'ordered_intents')));
      begin
        set local role authenticated;
        perform public.prepare_project_sync_transition(changed);
        reset role;
        raise exception using errcode='XX001',message='OPERATION_REUSE_ACCEPTED';
      exception when sqlstate 'P0001' then
        get stacked diagnostics saved_error=pg_exception_detail;
        reset role;
        if saved_error is null or position('OPERATION_ID_REUSED' in saved_error)=0 then raise exception 'WRONG_OPERATION_REUSE_ERROR'; end if;
      end;
      if (select count(*) from public.sync_batches where project_id=p)<>1 then raise exception 'REUSE_LEFT_LEDGER'; end if;
    end if;
    set local role authenticated;
    r:=public.prepare_project_sync_transition(request);
    if r->>'status'<>'replayed' then raise exception 'REPLAY_FAILED'; end if;
    r:=public.validate_project_sync_migration(p);
    if r->>'valid'<>'true' then raise exception 'INVALID_AFTER_PREPARE'; end if;
    r:=public.complete_project_sync_migration(p,device,1);
    if r->>'status'<>'id_based' then raise exception 'COMPLETE_FAILED'; end if;
    r:=public.prepare_project_sync_transition(request);
    if r->>'status'<>'replayed' then raise exception 'COMPLETED_REPLAY_FAILED'; end if;
    reset role;
    if pg_temp.transition_preserved(p) is distinct from before_rows then raise exception 'COMPLETE_MUTATED_CONTENT'; end if;
    raise notice 'PASS transition %',c;
  end loop;
  if has_function_privilege('anon','public.prepare_project_sync_transition(jsonb)','EXECUTE')
     or has_function_privilege('authenticated','private.project_transition_payload(uuid)','EXECUTE') then raise exception 'TRANSITION_ACL'; end if;
end $cases$;

-- A tombstoned folder does not reserve its path. A recorded parent ID is
-- authoritative; an uninitialized document with multiple possible parents is not.
do $folder_reuse$
declare
  u constant uuid := '97000000-0000-4000-8000-000000000001';
  p uuid; root uuid; retired uuid; replacement uuid; leaf uuid; doc uuid; device uuid;
  control uuid; hash bytea; c text; saved_error text; plan jsonb; request jsonb; r jsonb;
  expected_parent uuid; identified boolean; ambiguous boolean; deleted boolean;
  before_rows jsonb; before_doc jsonb; before_folders jsonb; before_projection jsonb;
begin
  foreach c in array array[
    'empty_reuse', 'unreferenced_reuse', 'identified_live', 'identified_deleted',
    'ambiguous_live', 'ambiguous_deleted', 'legacy_order_reuse', 'unique_descendant'
  ] loop
    p:=gen_random_uuid(); root:=gen_random_uuid(); retired:=gen_random_uuid();
    replacement:=gen_random_uuid(); leaf:=gen_random_uuid(); doc:=gen_random_uuid(); device:=gen_random_uuid();
    identified:=c in ('identified_live','identified_deleted');
    ambiguous:=c in ('ambiguous_live','ambiguous_deleted');
    deleted:=c in ('identified_deleted','ambiguous_deleted');
    expected_parent:=case when deleted then retired when identified or ambiguous then replacement
                          when c='unique_descendant' then leaf else root end;
    perform set_config('request.jwt.claim.sub',u::text,true);
    insert into public.projects(project_id,owner_id,name) values(p,u,'transition folder reuse '||c);
    insert into public.project_members(project_id,user_id,role) values(p,u,'owner');
    insert into public.folders(folder_id,project_id,parent_folder_id,name,revision,is_deleted,deleted_at,created_by,updated_by)
      values(root,p,null,'메인',1,false,null,u,u),
            (retired,p,root,'reused',4,true,now()-interval '1 day',u,u),
            (replacement,p,root,'reused',1,false,null,u,u);
    if c='unique_descendant' then
      insert into public.folders(folder_id,project_id,parent_folder_id,name,revision,created_by,updated_by)
        values(leaf,p,replacement,'leaf',1,u,u);
    end if;
    if c<>'empty_reuse' then
      set local role authenticated;
      perform public.commit_document(doc,p,0,gen_random_uuid(),device,
        case when identified or ambiguous then '메인/reused/chapter.txt'
             when c='unique_descendant' then '메인/reused/leaf/chapter.txt'
             else '메인/chapter.txt' end,'unchanged body',false,null);
      reset role;
      if deleted then update public.documents set is_deleted=true,deleted_at=now() where document_id=doc; end if;
      if identified then
        update public.documents set name='chapter.txt',parent_folder_id=expected_parent,
          structure_revision=3,storage_name_key=private.storage_name_v1('chapter.txt') where document_id=doc;
      end if;
    end if;
    if c='legacy_order_reuse' then
      hash:=extensions.digest(uuid_send(p)||convert_to('__antigravity__/tree-order.json','UTF8'),'sha1');
      hash:=set_byte(hash,6,(get_byte(hash,6)&15)|80); hash:=set_byte(hash,8,(get_byte(hash,8)&63)|128);
      control:=encode(substring(hash,1,16),'hex')::uuid;
      set local role authenticated;
      perform public.commit_document(control,p,0,gen_random_uuid(),device,'__antigravity__/tree-order.json',
        '{"tree_order":{"<root>":["reused","chapter.txt"],"메인/reused":[]}}',false,null);
      reset role;
    end if;
    before_rows:=pg_temp.transition_preserved(p);
    select to_jsonb(d) into before_doc from public.documents d where document_id=doc;
    select jsonb_agg(to_jsonb(f) order by folder_id),
           jsonb_agg(to_jsonb(f)-'storage_name_key' order by folder_id)
      into before_folders,before_projection from public.folders f where project_id=p;
    begin
      set local role authenticated;
      plan:=public.get_project_sync_transition_plan(p);
      reset role;
      if ambiguous then raise exception using errcode='XX001',message='AMBIGUOUS_PARENT_ACCEPTED '||c; end if;
    exception when sqlstate 'P0001' then
      get stacked diagnostics saved_error=message_text;
      reset role;
      if not ambiguous or saved_error<>'PATH_CONFLICT' then
        raise exception 'wrong folder reuse error %: %',c,saved_error;
      end if;
      if exists(select 1 from public.project_sync_settings where project_id=p)
         or exists(select 1 from public.project_sync_migrations where project_id=p)
         or exists(select 1 from public.sync_batches where project_id=p)
         or exists(select 1 from public.tree_orders where project_id=p)
         or pg_temp.transition_preserved(p) is distinct from before_rows
         or (select to_jsonb(d) from public.documents d where document_id=doc) is distinct from before_doc
         or (select jsonb_agg(to_jsonb(f) order by folder_id) from public.folders f where project_id=p)
            is distinct from before_folders then raise exception 'AMBIGUOUS_PREFLIGHT_WROTE'; end if;
      raise notice 'PASS folder reuse % (fail-closed)',c;
      continue;
    end;
    if (identified or c='empty_reuse') and plan#>'{payload,documents}'<>'[]'::jsonb then
      raise exception 'EXISTING_ID_REINITIALIZED %',c;
    end if;
    request:=pg_temp.transition_request(p,device,plan->'payload');
    set local role authenticated;
    r:=public.prepare_project_sync_transition(request);
    reset role;
    if r->>'applied' is distinct from 'true'
       or pg_temp.transition_preserved(p) is distinct from before_rows
       or (select jsonb_agg(to_jsonb(f) order by folder_id) from public.folders f where project_id=p)
          is distinct from before_folders then raise exception 'REUSE_PREPARE_PRESERVATION %',c; end if;
    if c<>'empty_reuse' and not exists(select 1 from public.documents where document_id=doc
      and parent_folder_id=expected_parent and name='chapter.txt' and is_deleted=deleted
      and structure_revision=case when identified then 3 else 1 end) then
      raise exception 'REUSE_PARENT_OR_REVISION_CHANGED %',c;
    end if;
    if identified and (select to_jsonb(d) from public.documents d where document_id=doc) is distinct from before_doc then
      raise exception 'IDENTIFIED_DOCUMENT_REWRITTEN %',c;
    end if;
    if c='legacy_order_reuse' and (
      not exists(select 1 from public.tree_orders where project_id=p and parent_folder_id=root and children=array[replacement,doc])
      or not exists(select 1 from public.tree_orders where project_id=p and parent_folder_id=replacement and children='{}'::uuid[])
      or exists(select 1 from public.tree_orders where project_id=p and parent_folder_id=retired)
    ) then raise exception 'REUSE_ORDER_LOST'; end if;
    set local role authenticated;
    r:=public.validate_project_sync_migration(p);
    if r->>'valid' is distinct from 'true' then raise exception 'REUSE_INVALID %',c; end if;
    r:=public.prepare_project_sync_transition(request);
    if r->>'status' is distinct from 'replayed' then raise exception 'REUSE_REPLAY_FAILED %',c; end if;
    r:=public.complete_project_sync_migration(p,device,1);
    if r->>'status' is distinct from 'id_based' then raise exception 'REUSE_COMPLETE_FAILED %',c; end if;
    r:=public.prepare_project_sync_transition(request);
    if r->>'status' is distinct from 'replayed' then raise exception 'REUSE_COMPLETED_REPLAY_FAILED %',c; end if;
    reset role;
    if pg_temp.transition_preserved(p) is distinct from before_rows
       or (select jsonb_agg(to_jsonb(f)-'storage_name_key' order by folder_id) from public.folders f where project_id=p)
          is distinct from before_projection then raise exception 'REUSE_COMPLETE_PRESERVATION %',c; end if;
    raise notice 'PASS folder reuse %',c;
  end loop;
end $folder_reuse$;

-- 0.3 is enabled ONLY in this rolled-back, disposable CI transaction.
-- The migration itself must leave activation to a separately approved operation.
do $contract03$
declare
  u constant uuid := '97000000-0000-4000-8000-000000000001';
  v02 constant text := '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670';
  v03 constant text := 'abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c';
  profile constant text := '07e2e557921c17750f960d6b88b72dadb15d3aee45658d5260a3494607012b77';
  p uuid; f uuid; doc uuid; device uuid; control uuid; hash bytea;
  c text; name text; expected text; message text; plan jsonb; request jsonb; r jsonb; h jsonb;
  before_rows jsonb; before_doc jsonb; before_folders jsonb;
  windows_caps constant text[] := array['atomic_structure_commit','contract_allowlist_validation',
    'project_mode_migration_lock','folder_tombstones','id_tree_validation','legacy_epoch_zero_adapter',
    'storage_name_v2','document_commit_v1'];
begin
  if (select enabled from private.sync_contract_allowlist where canonical_contract_sha256=v03) then
    raise exception 'MIGRATION_ENABLED_CONTRACT_03';
  end if;
  foreach c in array array['disabled','revoked','future','ordinary','deleted','legacy_order',
    'unassigned','excluded','supplementary_adjacency','collision','wrong_profile','wrong_capability',
    'wrong_version','active_02','unknown_target','disabled_after_plan','revoked_after_plan',
    'future_after_plan','wrong_payload_target'] loop
    update private.sync_contract_allowlist set enabled=(c<>'disabled'),
      revoked_at=case when c='revoked' then now() else null end,
      valid_from=case when c='future' then now()+interval '1 day' else now()-interval '1 day' end
      where canonical_contract_sha256=v03;
    perform set_config('writerpad.contract_sha256',v02,true);
    perform set_config('request.jwt.claim.sub',u::text,true);
    p:=gen_random_uuid(); f:=gen_random_uuid(); doc:=gen_random_uuid(); device:=gen_random_uuid();
    name:='Straße.txt'; expected:=null;
    insert into public.projects(project_id,owner_id,name) values(p,u,'transition 0.3 '||c);
    insert into public.project_members(project_id,user_id,role) values(p,u,'owner');
    insert into public.folders(folder_id,project_id,parent_folder_id,name,revision,created_by,updated_by)
      values(f,p,null,'메인',1,u,u);
    set local role authenticated;
    perform public.commit_document(doc,p,0,gen_random_uuid(),device,'메인/'||name,'preserved 0.3 body',false,null);
    reset role;
    if c='deleted' then update public.documents set is_deleted=true,deleted_at=now() where document_id=doc; end if;
    if c='unassigned' then name:=chr(129768)||'.txt'; expected:='STORAGE_NAME_UNASSIGNED'; end if;
    if c='excluded' then name:=chr(57344)||'.txt'; expected:='STORAGE_NAME_UNSUPPORTED_SCALAR'; end if;
    if c='supplementary_adjacency' then name:=chr(65601)||chr(769)||'.txt'; expected:='STORAGE_NAME_INVALID'; end if;
    if expected is not null then update public.documents set relative_path='메인/'||name where document_id=doc; end if;
    if c in ('disabled','revoked','future','unknown_target') then expected:='CONTRACT_NOT_ALLOWED'; end if;
    if c='active_02' then
      perform public.begin_project_sync_migration(p,device,v02); expected:='CONTRACT_NOT_ALLOWED';
    end if;
    if c='legacy_order' then
      hash:=extensions.digest(uuid_send(p)||convert_to('__antigravity__/tree-order.json','UTF8'),'sha1');
      hash:=set_byte(hash,6,(get_byte(hash,6)&15)|80); hash:=set_byte(hash,8,(get_byte(hash,8)&63)|128);
      control:=encode(substring(hash,1,16),'hex')::uuid;
      set local role authenticated;
      perform public.commit_document(control,p,0,gen_random_uuid(),device,'__antigravity__/tree-order.json',
        '{"tree_order":{"<root>":["Straße.txt"]}}',false,null);
      reset role;
    end if;
    before_rows:=pg_temp.transition_preserved(p);
    select to_jsonb(d) into before_doc from public.documents d where document_id=doc;
    select jsonb_agg(to_jsonb(t) order by folder_id) into before_folders from public.folders t where project_id=p;
    begin
      set local role authenticated;
      plan:=public.get_project_sync_transition_plan_for_contract(p,case when c='unknown_target' then repeat('0',64) else v03 end);
      reset role;
      if expected is not null then raise exception using errcode='XX001',message='03_PREFLIGHT_ACCEPTED '||c; end if;
    exception when sqlstate 'P0001' then
      get stacked diagnostics message=message_text; reset role;
      if message is distinct from expected then raise exception '03 wrong preflight %: %',c,message; end if;
      if pg_temp.transition_preserved(p) is distinct from before_rows
        or (select to_jsonb(d) from public.documents d where document_id=doc) is distinct from before_doc
        or exists(select 1 from public.sync_batches where project_id=p)
        or (c<>'active_02' and exists(select 1 from public.project_sync_settings where project_id=p)) then
        raise exception '03_PREFLIGHT_WROTE %',c;
      end if;
      if c='active_02' and (select active_contract_sha256 from public.project_sync_settings where project_id=p)<>v02 then
        raise exception '03_REPINNED_02';
      end if;
      raise notice 'PASS transition 0.3 % (fail-closed)',c;
      continue;
    end;
    h:=plan->'handshake';
    if plan->>'profile_sha256'<>profile or plan->>'target_contract_sha256'<>v03
      or plan#>>'{payload,target_contract_sha256}'<>v03
      or h->>'supported'<>'true' or h->>'contract_version'<>'0.3.0'
      or h->>'canonical_contract_sha256'<>v03 or h->>'server_contract_sha256'<>v03
      or h->>'project_sync_mode'<>'LEGACY' or h->>'migration_epoch'<>'0'
      or h->'server_capabilities'<>to_jsonb(windows_caps) or h->>'server_protocol_version'<>'3'
      or h->'supported_protocol_versions'<>'[3]'::jsonb then raise exception '03_PLAN_HANDSHAKE_MISMATCH'; end if;
    request:=pg_temp.transition_request(p,device,plan->'payload',v03);
    if c in ('disabled_after_plan','revoked_after_plan','future_after_plan') then
      update private.sync_contract_allowlist set enabled=(c<>'disabled_after_plan'),
        revoked_at=case when c='revoked_after_plan' then now() else null end,
        valid_from=case when c='future_after_plan' then now()+interval '1 day' else now()-interval '1 day' end
        where canonical_contract_sha256=v03;
      expected:='CONTRACT_NOT_ALLOWED';
    end if;
    if c='wrong_payload_target' then
      request:=jsonb_set(request,'{ordered_intents,0,payload,target_contract_sha256}',to_jsonb(v02));
      expected:='INVALID_ARGUMENT';
    end if;
    if c='wrong_profile' then
      request:=jsonb_set(request,'{ordered_intents,0,payload,profile_sha256}',to_jsonb(private.project_transition_profile(v02)));
      expected:='INVALID_ARGUMENT';
    end if;
    if c='wrong_capability' then
      request:=jsonb_set(request,'{batch,client_capabilities,6}','"storage_name_v1"'); expected:='TRANSITION_PREPARATION_FAILED';
    end if;
    if c='wrong_version' then request:=jsonb_set(request,'{batch,contract_version}','"0.2.0"'); expected:='TRANSITION_PREPARATION_FAILED'; end if;
    if c='collision' then
      insert into public.folders(folder_id,project_id,parent_folder_id,name,revision,created_by,updated_by)
        values(gen_random_uuid(),p,f,'STRASSE.TXT',1,u,u);
      request:=pg_temp.transition_request(p,device,private.project_transition_payload(p,v03),v03);
      expected:='TRANSITION_PREPARATION_FAILED';
    end if;
    begin
      set local role authenticated;
      r:=public.prepare_project_sync_transition(request);
      reset role;
      if expected is not null then raise exception using errcode='XX001',message='03_PREPARE_ACCEPTED '||c; end if;
    exception when sqlstate 'P0001' then
      get stacked diagnostics message=message_text; reset role;
      if message is distinct from expected then raise exception '03 wrong prepare %: %',c,message; end if;
      if pg_temp.transition_preserved(p) is distinct from before_rows
        or (select to_jsonb(d) from public.documents d where document_id=doc) is distinct from before_doc
        or exists(select 1 from public.sync_batches where project_id=p)
        or exists(select 1 from public.project_sync_settings where project_id=p) then raise exception '03_FAILED_PREPARE_WROTE'; end if;
      raise notice 'PASS transition 0.3 % (rollback)',c;
      continue;
    end;
    if r->>'applied'<>'true' or pg_temp.transition_preserved(p) is distinct from before_rows
      or not exists(select 1 from public.documents where document_id=doc and parent_folder_id=f
        and name='Straße.txt' and structure_revision=1 and storage_name_key=convert_to('strasse.txt','UTF8'))
      then raise exception '03_INITIALIZATION_FAILED'; end if;
    if c='legacy_order' and not exists(select 1 from public.tree_orders where project_id=p and parent_folder_id=f and children=array[doc]) then
      raise exception '03_ROOT_ORDER_LOST';
    end if;
    set local role authenticated;
    r:=public.prepare_project_sync_transition(request);
    if r->>'status'<>'replayed' then raise exception '03_REPLAY_FAILED'; end if;
    r:=public.validate_project_sync_migration(p);
    if r->>'valid'<>'true' then raise exception '03_VALIDATION_FAILED'; end if;
    r:=public.complete_project_sync_migration(p,device,1);
    if r->>'status'<>'id_based' then raise exception '03_COMPLETE_FAILED'; end if;
    plan:=public.get_project_sync_transition_plan_for_contract(p,v03);
    h:=public.get_sync_handshake(p,v03);
    if plan->'handshake'<>h or h->>'contract_version'<>'0.3.0' or h->>'canonical_contract_sha256'<>v03
      or h->>'server_contract_sha256'<>v03 or h->>'project_sync_mode'<>'ID_BASED' or h->>'migration_epoch'<>'1'
      or h->'server_capabilities'<>to_jsonb(windows_caps) or h->>'supported'<>'true' then raise exception '03_POST_HANDSHAKE_MISMATCH'; end if;
    h:=public.get_sync_handshake(p,v02);
    if h->>'supported'<>'false' then raise exception '03_ACCEPTED_02_HANDSHAKE'; end if;
    r:=public.prepare_project_sync_transition(request);
    if r->>'status'<>'replayed' then raise exception '03_COMPLETED_REPLAY_FAILED'; end if;
    begin
      perform public.get_project_sync_transition_plan(p);
      raise exception using errcode='XX001',message='03_ACCEPTED_02_PLAN';
    exception when sqlstate 'P0001' then
      if sqlerrm<>'CONTRACT_NOT_ALLOWED' then raise; end if;
    end;
    reset role;
    if pg_temp.transition_preserved(p) is distinct from before_rows
      or (select active_contract_sha256 from public.project_sync_settings where project_id=p)<>v03
      or not exists(select 1 from public.folders where folder_id=f and storage_name_key=private.storage_name_v2('메인'))
      then raise exception '03_COMPLETE_PRESERVATION_FAILED'; end if;
    raise notice 'PASS transition 0.3 %',c;
  end loop;
  if has_function_privilege('anon','public.get_project_sync_transition_plan_for_contract(uuid,text)','EXECUTE')
     or has_function_privilege('authenticated','private.project_transition_payload(uuid,text)','EXECUTE') then raise exception '03_TRANSITION_ACL'; end if;
end $contract03$;
rollback;
\echo 'Product transition initialization regression passed'
