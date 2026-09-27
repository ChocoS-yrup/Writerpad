-- Explicitly negotiated initialization extension; no deployment-time data changes.
begin;

create or replace function private.project_transition_payload(p_project_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_folders jsonb; v_documents jsonb; v_orders jsonb; v_paths jsonb;
  v_initial jsonb := '[]'; v_projected jsonb := '[]'; v_children jsonb;
  v_doc public.documents%rowtype; v_entry record; v_child record; v_parent uuid; v_id uuid;
  v_name text; v_parent_path text; v_count integer; v_control jsonb;
  v_baseline text; v_hash bytea;
begin
  if (select count(*) from public.folders where project_id=p_project_id)>1000
     or (select count(*) from public.documents where project_id=p_project_id)>1000 then
    raise exception 'TRANSITION_SIZE_LIMIT';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',folder_id,'parent',parent_folder_id,
    'name',name,'revision',revision,'deleted',is_deleted) order by folder_id),'[]')
    into v_folders from public.folders where project_id=p_project_id;
  select coalesce(jsonb_agg(jsonb_build_object('id',document_id,'parent',parent_folder_id,
    'name',name,'revision',revision,'structure_revision',structure_revision,
    'storage_key',encode(storage_name_key,'hex'),'path',relative_path,'deleted',is_deleted,
    'content_sha256',private.content_sha256(content)) order by document_id),'[]')
    into v_documents from public.documents where project_id=p_project_id;
  select coalesce(jsonb_agg(jsonb_build_object('id',tree_order_id,'parent',parent_folder_id,
    'children',children,'revision',revision) order by tree_order_id),'[]')
    into v_orders from public.tree_orders where project_id=p_project_id;
  v_baseline := private.jsonb_rfc8785_sha256(jsonb_build_object(
    'folders',v_folders,'documents',v_documents,'orders',v_orders));
  with recursive paths(id,path) as (
    select folder_id,name from public.folders where project_id=p_project_id and parent_folder_id is null
    union all
    select f.folder_id,p.path || '/' || f.name from public.folders f
      join paths p on f.parent_folder_id=p.id where f.project_id=p_project_id
  ) select coalesce(jsonb_agg(jsonb_build_object('id',id,'path',path) order by id),'[]') into v_paths from paths;
  if jsonb_array_length(v_paths) <> jsonb_array_length(v_folders) then raise exception 'FOLDER_CYCLE'; end if;
  if exists(select 1 from jsonb_array_elements(v_paths) p group by p->>'path' having count(*)>1) then
    raise exception 'PATH_CONFLICT';
  end if;
  for v_doc in select * from public.documents where project_id=p_project_id order by document_id loop
    if private.is_contract_migration_control_document(v_doc) then continue; end if;
    if split_part(v_doc.relative_path,'/',1)='__antigravity__' then raise exception 'INVALID_CONTROL_DOCUMENT'; end if;
    if v_doc.name is not null and v_doc.structure_revision is not null then
      if v_doc.structure_revision<1 then raise exception 'INVARIANT_VIOLATION'; end if;
      perform private.storage_name_v1(v_doc.name);
      -- Existing contract metadata must agree with the immutable recorded path.
      select p->>'path' into v_parent_path from jsonb_array_elements(v_paths) p
        where (p->>'id')::uuid=v_doc.parent_folder_id;
      if v_doc.relative_path is distinct from
        (case when v_doc.parent_folder_id is null then '' else v_parent_path || '/' end || v_doc.name) then
        raise exception 'STRUCTURE_REVISION_CONFLICT';
      end if;
      continue;
    end if;
    if v_doc.name is not null or v_doc.structure_revision is not null
       or v_doc.parent_folder_id is not null or v_doc.storage_name_key is not null then
      raise exception 'INVARIANT_VIOLATION';
    end if;
    v_name := regexp_replace(v_doc.relative_path,'^.*/','');
    perform private.storage_name_v1(v_name);
    v_parent := null;
    if position('/' in v_doc.relative_path)>0 then
      v_parent_path := left(v_doc.relative_path,length(v_doc.relative_path)-length(v_name)-1);
      select count(*),min(p->>'id')::uuid into v_count,v_parent
        from jsonb_array_elements(v_paths) p where p->>'path'=v_parent_path;
      if v_count<>1 then raise exception 'FOLDER_NOT_FOUND'; end if;
    end if;
    v_initial := v_initial || jsonb_build_array(jsonb_build_object(
      'id',v_doc.document_id,'name',v_name,'parent_folder_id',v_parent));
  end loop;
  -- Legacy names are an exact projection only, never authority for creating IDs.
  select content::jsonb into v_control from public.documents d where project_id=p_project_id
    and not is_deleted and relative_path='__antigravity__/tree-order.json'
    and private.is_contract_migration_control_document(d);
  if v_control is not null then
    if jsonb_typeof(v_control->'tree_order') is distinct from 'object' then raise exception 'TREE_REFERENCE_NOT_FOUND'; end if;
    for v_entry in select * from jsonb_each(v_control->'tree_order') order by key loop
      v_parent_path := case when v_entry.key='<root>' then '메인' else v_entry.key end;
      select count(*),min(p->>'id')::uuid into v_count,v_parent
        from jsonb_array_elements(v_paths) p join public.folders f on f.folder_id=(p->>'id')::uuid
        where p->>'path'=v_parent_path and not f.is_deleted;
      if v_count<>1 or jsonb_typeof(v_entry.value)<>'array' then raise exception 'TREE_REFERENCE_NOT_FOUND'; end if;
      v_children := '[]';
      for v_child in select value from jsonb_array_elements(v_entry.value) loop
        if jsonb_typeof(v_child.value)<>'string' then raise exception 'TREE_REFERENCE_NOT_FOUND'; end if;
        v_name := v_child.value #>> '{}';
        select count(*),min(id)::uuid into v_count,v_id from (
          select folder_id::text id from public.folders where project_id=p_project_id
            and parent_folder_id=v_parent and name=v_name and not is_deleted
          union all
          select d.document_id::text from public.documents d where d.project_id=p_project_id
            and not d.is_deleted and d.relative_path=v_parent_path || '/' || v_name
            and not private.is_contract_migration_control_document(d)
        ) entities;
        if v_count<>1 then raise exception 'TREE_REFERENCE_NOT_FOUND'; end if;
        if v_children @> jsonb_build_array(v_id) then raise exception 'TREE_REFERENCE_DUPLICATED'; end if;
        v_children := v_children || jsonb_build_array(v_id);
      end loop;
      if jsonb_array_length(v_orders)>0 then
        if not exists(select 1 from public.tree_orders where project_id=p_project_id
          and parent_folder_id=v_parent and to_jsonb(children)=v_children) then
          raise exception 'TREE_REFERENCE_NOT_FOUND';
        end if;
      else
        v_hash := extensions.digest(uuid_send(p_project_id) || convert_to('migration-tree-order:' || v_parent::text,'UTF8'),'sha1');
        v_hash := set_byte(v_hash,6,(get_byte(v_hash,6)&15)|80);
        v_hash := set_byte(v_hash,8,(get_byte(v_hash,8)&63)|128);
        v_projected := v_projected || jsonb_build_array(jsonb_build_object(
          'id',encode(substring(v_hash,1,16),'hex')::uuid,'parent_folder_id',v_parent,'children',v_children));
      end if;
    end loop;
  end if;
  return jsonb_build_object('profile_sha256','5c5736ec9bda42f80b75dd8f863bb01b0bba8cef1ebe96675333db634b560c81',
    'baseline_sha256',v_baseline,'documents',v_initial,'orders',v_projected);
end;
$$;

create or replace function public.get_project_sync_transition_plan(p_project_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_settings public.project_sync_settings%rowtype; v_migration public.project_sync_migrations%rowtype;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.has_project_role(p_project_id,auth.uid(),'owner') then raise exception 'FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtextextended('project:' || p_project_id::text,0));
  if not private.has_project_role(p_project_id,auth.uid(),'owner') then raise exception 'FORBIDDEN'; end if;
  select * into v_settings from public.project_sync_settings where project_id=p_project_id;
  if v_settings.project_sync_mode in ('MIGRATING','ID_BASED') and v_settings.active_contract_sha256 is distinct from
    '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670' then raise exception 'CONTRACT_NOT_ALLOWED'; end if;
  select * into v_migration from public.project_sync_migrations where project_id=p_project_id
    order by migration_epoch desc limit 1;
  return jsonb_build_object('profile_sha256','5c5736ec9bda42f80b75dd8f863bb01b0bba8cef1ebe96675333db634b560c81',
    'project_id',p_project_id,'mode',coalesce(v_settings.project_sync_mode,'LEGACY'),
    'epoch',coalesce(v_settings.migration_epoch,0),'started_by_device_id',v_migration.started_by_device_id,
    'started_by_user_id',v_migration.started_by_user_id,
    'payload',case when v_settings.project_sync_mode='ID_BASED' then null else private.project_transition_payload(p_project_id) end);
end;
$$;

-- Rename once, preserving the complete old dispatcher for every other intent.
do $$ begin
  if to_regprocedure('private.apply_structure_intent_before_initialization(uuid,uuid,jsonb)') is null then
    alter function private.apply_structure_intent(uuid,uuid,jsonb) rename to apply_structure_intent_before_initialization;
  end if;
end $$;

create or replace function private.apply_structure_intent(p_project_id uuid,p_user_id uuid,p_intent jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_payload jsonb; v_entry jsonb; v_validation jsonb;
begin
  if p_intent->>'entity_kind' is distinct from 'project' or p_intent->>'intent_kind' is distinct from 'migrate' then
    return private.apply_structure_intent_before_initialization(p_project_id,p_user_id,p_intent);
  end if;
  if not private.has_project_role(p_project_id,p_user_id,'owner') or p_user_id is distinct from auth.uid() then
    raise exception 'FORBIDDEN';
  end if;
  if (p_intent->>'entity_id')::uuid is distinct from p_project_id
     or (p_intent->>'base_revision')::bigint is distinct from 0 then raise exception 'INVALID_ARGUMENT'; end if;
  if not exists(select 1 from public.sync_batches b join public.project_sync_migrations m
       on m.project_id=b.project_id and m.migration_epoch=b.migration_epoch
       join public.project_sync_settings s on s.project_id=b.project_id
       where b.batch_id=(p_intent->>'batch_id')::uuid and b.project_id=p_project_id
         and b.writer_user_id=p_user_id and m.started_by_user_id=p_user_id
         and b.writer_device_id=m.started_by_device_id and m.completed_at is null
         and b.canonical_contract_sha256='416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670'
         and s.active_contract_sha256=b.canonical_contract_sha256
         and s.project_sync_mode='MIGRATING' and s.migration_epoch=b.migration_epoch
         and b.project_sync_mode='MIGRATING') then raise exception 'MIGRATION_LOCKED'; end if;
  v_payload := private.project_transition_payload(p_project_id);
  if p_intent->'payload' is distinct from v_payload then raise exception 'TRANSITION_BASELINE_CHANGED'; end if;
  for v_entry in select value from jsonb_array_elements(v_payload->'documents') loop
    update public.documents set name=v_entry->>'name',parent_folder_id=(v_entry->>'parent_folder_id')::uuid,
      storage_name_key=private.storage_name_v1(v_entry->>'name'),structure_revision=1,
      updated_at=transaction_timestamp(),updated_by=p_user_id
      where document_id=(v_entry->>'id')::uuid and project_id=p_project_id;
  end loop;
  for v_entry in select value from jsonb_array_elements(v_payload->'orders') loop
    insert into public.tree_orders(tree_order_id,project_id,parent_folder_id,children,revision,created_by,updated_by)
    values((v_entry->>'id')::uuid,p_project_id,(v_entry->>'parent_folder_id')::uuid,
      array(select value::uuid from jsonb_array_elements_text(v_entry->'children')),1,p_user_id,p_user_id);
  end loop;
  v_validation := public.validate_project_sync_migration(p_project_id);
  if (v_validation->>'valid')::boolean is distinct from true then
    raise exception using message='TRANSITION_VALIDATION_FAILED',detail=v_validation::text;
  end if;
  return 1;
end;
$$;

create or replace function public.prepare_project_sync_transition(p_request jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_project uuid := (p_request->>'project_id')::uuid; v_result jsonb; v_payload jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.has_project_role(v_project,auth.uid(),'owner') then raise exception 'FORBIDDEN'; end if;
  perform pg_advisory_xact_lock(hashtextextended('project:' || v_project::text,0));
  if not private.has_project_role(v_project,auth.uid(),'owner') then raise exception 'FORBIDDEN'; end if;
  if p_request->>'project_sync_mode' is distinct from 'MIGRATING'
     or p_request#>>'{batch,canonical_contract_sha256}' is distinct from
       '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670'
     or (p_request->>'migration_epoch')::integer is distinct from 1
     or jsonb_array_length(p_request->'ordered_intents') is distinct from 1
     or p_request#>>'{ordered_intents,0,entity_kind}' is distinct from 'project'
     or p_request#>>'{ordered_intents,0,intent_kind}' is distinct from 'migrate'
     or p_request#>>'{ordered_intents,0,payload,profile_sha256}' is distinct from
       '5c5736ec9bda42f80b75dd8f863bb01b0bba8cef1ebe96675333db634b560c81' then raise exception 'INVALID_ARGUMENT'; end if;
  -- Replay is checked by the existing immutable request digest, before any begin.
  if not exists(select 1 from public.sync_batches where batch_id=(p_request#>>'{batch,batch_id}')::uuid) then
    v_payload := private.project_transition_payload(v_project);
    if p_request#>'{ordered_intents,0,payload}' is distinct from v_payload then raise exception 'TRANSITION_BASELINE_CHANGED'; end if;
    if not exists(select 1 from public.project_sync_settings where project_id=v_project and project_sync_mode<>'LEGACY') then
      perform public.begin_project_sync_migration(v_project,(p_request#>>'{batch,writer_device_id}')::uuid,
        p_request#>>'{batch,canonical_contract_sha256}');
    end if;
  end if;
  v_result := public.atomic_structure_commit(p_request);
  if (v_result->>'applied')::boolean is distinct from true then
    -- Raising rolls back the begin and failed batch ledger in this RPC transaction.
    raise exception using message='TRANSITION_PREPARATION_FAILED',detail=v_result::text;
  end if;
  return v_result;
end;
$$;

revoke all on function private.project_transition_payload(uuid) from public,anon,authenticated;
revoke all on function private.apply_structure_intent(uuid,uuid,jsonb) from public,anon,authenticated;
revoke all on function private.apply_structure_intent_before_initialization(uuid,uuid,jsonb) from public,anon,authenticated;
revoke all on function public.get_project_sync_transition_plan(uuid) from public,anon;
revoke all on function public.prepare_project_sync_transition(jsonb) from public,anon;
grant execute on function public.get_project_sync_transition_plan(uuid) to authenticated;
grant execute on function public.prepare_project_sync_transition(jsonb) to authenticated;
commit;
