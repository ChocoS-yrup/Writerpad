\set ON_ERROR_STOP on
begin;
set local statement_timeout = '30s';
do $$ begin
  if current_database()<>'writerpad_stage7' or current_user<>'postgres' then raise exception 'TRANSITION_FIXTURE_SCOPE'; end if;
end $$;
insert into auth.users(id) values ('97000000-0000-4000-8000-000000000001'),('97000000-0000-4000-8000-000000000002');
update private.sync_contract_allowlist set enabled=true where canonical_contract_sha256='416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670';

create function pg_temp.transition_request(p uuid,d uuid,payload jsonb) returns jsonb
language plpgsql as $$
declare b uuid:=gen_random_uuid(); i jsonb; caps text[];
begin
  select allowed_client_capabilities into caps from private.sync_contract_allowlist
    where canonical_contract_sha256='416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670';
  i:=jsonb_build_array(jsonb_build_object('sequence',1,'operation_id',gen_random_uuid(),'batch_id',b,
    'entity_kind','project','entity_id',p,'intent_kind','migrate','base_revision',0,
    'payload',payload,'payload_sha256',private.jsonb_rfc8785_sha256(payload)));
  return jsonb_build_object('kind','atomic_structure_commit_request','project_id',p,
    'project_sync_mode','MIGRATING','migration_epoch',1,'ordered_intents',i,
    'batch',jsonb_build_object('batch_id',b,'writer_device_id',d,'client_build_id','transition-ci',
      'sync_protocol_version',3,'contract_version','0.2.0','client_capabilities',to_jsonb(caps),
      'canonical_contract_sha256','416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670',
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
rollback;
\echo 'Product transition initialization regression passed'
