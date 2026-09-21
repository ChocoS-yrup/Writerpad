-- 일반 동기화 영구 삭제 표식. 실제 원고 tombstone과 이력은 유지한다.
-- 운영 적용은 별도 배포 단계에서 수행한다. 기존 0.2.0 봉투와 해시는 바꾸지 않는다.
begin;

create or replace function private.apply_contract_trash_purge(
  p_project_id uuid, p_user_id uuid, p_intent jsonb
) returns bigint language plpgsql security invoker set search_path = '' as $$
declare
  v_id uuid := (p_intent->>'entity_id')::uuid;
  v_base bigint := (p_intent->>'base_revision')::bigint;
  v_path constant text := '__antigravity__/trash-purge.json';
  v_hash bytea;
  v_expected uuid;
  v_content text := p_intent->'payload'->>'content';
  v_payload jsonb;
  v_previous jsonb := '{"version":1,"purged_revisions":{},"empty_generation":""}'::jsonb;
  v_marker public.documents%rowtype;
  v_document public.documents%rowtype;
  v_entry record;
  v_revision bigint;
  v_version uuid;
  v_device uuid;
  v_now timestamptz := pg_catalog.transaction_timestamp();
begin
  if auth.uid() is distinct from p_user_id or not private.has_project_role(p_project_id, p_user_id, 'editor') then
    raise exception using errcode='P0001', message='FORBIDDEN';
  end if;
  if p_intent->>'entity_kind' is distinct from 'trash_purge'
     or p_intent->>'intent_kind' is distinct from 'update'
     or pg_catalog.jsonb_typeof(p_intent->'payload') is distinct from 'object'
     or ((p_intent->'payload') - 'content') <> '{}'::jsonb
     or pg_catalog.jsonb_typeof(p_intent->'payload'->'content') is distinct from 'string'
     or pg_catalog.octet_length(v_content) > 10485760 or v_base is null or v_base < 0 then
    raise exception using errcode='P0001', message='INVALID_ARGUMENT';
  end if;
  begin
    v_payload := v_content::jsonb;
  exception when others then
    raise exception using errcode='P0001', message='INVALID_ARGUMENT';
  end;
  if pg_catalog.jsonb_typeof(v_payload) is distinct from 'object'
     or (v_payload - array['version','purged_revisions','empty_generation']) <> '{}'::jsonb
     or pg_catalog.jsonb_typeof(v_payload->'version') is distinct from 'number'
     or (v_payload->'version')::text is distinct from '1'
     or pg_catalog.jsonb_typeof(v_payload->'purged_revisions') is distinct from 'object'
     or pg_catalog.jsonb_typeof(v_payload->'empty_generation') is distinct from 'string'
     or (v_payload->>'empty_generation' <> '' and v_payload->>'empty_generation' !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
    raise exception using errcode='P0001', message='INVALID_ARGUMENT';
  end if;
  -- UUID v5를 기존 pgcrypto로 계산해 클라이언트의 고정 숨은 문서와 맞춘다.
  v_hash := extensions.digest(pg_catalog.uuid_send(p_project_id) || pg_catalog.convert_to(v_path,'UTF8'),'sha1');
  v_hash := pg_catalog.set_byte(v_hash,6,(pg_catalog.get_byte(v_hash,6) & 15) | 80);
  v_hash := pg_catalog.set_byte(v_hash,8,(pg_catalog.get_byte(v_hash,8) & 63) | 128);
  v_expected := pg_catalog.encode(pg_catalog.substring(v_hash,1,16),'hex')::uuid;
  if v_id is distinct from v_expected then
    raise exception using errcode='P0001', message='INVALID_ARGUMENT';
  end if;
  select * into v_marker from public.documents where document_id=v_id for update;
  if found then
    if v_marker.project_id <> p_project_id or v_marker.relative_path <> v_path or v_marker.is_deleted
       or v_marker.name is not null or v_marker.parent_folder_id is not null
       or v_marker.structure_revision is not null or v_marker.storage_name_key is not null then
      raise exception using errcode='P0001', message='INVALID_ARGUMENT';
    end if;
    if v_marker.revision <> v_base then
      raise exception using errcode='P0001', message='REVISION_CONFLICT';
    end if;
    begin
      v_previous := v_marker.content::jsonb;
    exception when others then
      raise exception using errcode='P0001', message='INVALID_ARGUMENT';
    end;
  elsif v_base <> 0 then
    raise exception using errcode='P0001', message='REVISION_CONFLICT';
  end if;
  -- 손상되거나 비정규인 기존 표식을 덮어써 purge 감사 상태를 잃지 않는다.
  if pg_catalog.jsonb_typeof(v_previous) is distinct from 'object'
     or (v_previous - array['version','purged_revisions','empty_generation']) <> '{}'::jsonb
     or pg_catalog.jsonb_typeof(v_previous->'version') is distinct from 'number'
     or (v_previous->'version')::text is distinct from '1'
     or pg_catalog.jsonb_typeof(v_previous->'purged_revisions') is distinct from 'object'
     or pg_catalog.jsonb_typeof(v_previous->'empty_generation') is distinct from 'string'
     or (v_previous->>'empty_generation' <> '' and v_previous->>'empty_generation' !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
    raise exception using errcode='P0001', message='INVALID_ARGUMENT';
  end if;
  for v_entry in select * from pg_catalog.jsonb_each(v_payload->'purged_revisions') loop
    if v_entry.key !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or pg_catalog.jsonb_typeof(v_entry.value) <> 'number'
       or v_entry.value::text !~ '^[1-9][0-9]*$'
       or (v_entry.value::text)::numeric > 9223372036854775807 then
      raise exception using errcode='P0001', message='INVALID_ARGUMENT';
    end if;
  end loop;
  for v_entry in select * from pg_catalog.jsonb_each(v_previous->'purged_revisions') loop
    if v_entry.key !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or pg_catalog.jsonb_typeof(v_entry.value) <> 'number'
       or v_entry.value::text !~ '^[1-9][0-9]*$'
       or (v_entry.value::text)::numeric > 9223372036854775807 then
      raise exception using errcode='P0001', message='INVALID_ARGUMENT';
    end if;
  end loop;
  -- 이전 표식을 제거하거나 revision을 낮추면 다른 기기의 재등장을 막을 수 없다.
  for v_entry in select * from pg_catalog.jsonb_each(v_previous->'purged_revisions') loop
    if not ((v_payload->'purged_revisions') ? v_entry.key)
       or (v_payload->'purged_revisions'->>v_entry.key)::numeric < (v_entry.value #>> '{}')::numeric then
      raise exception using errcode='P0001', message='INVALID_ARGUMENT';
    end if;
  end loop;
  if v_previous->>'empty_generation' <> '' and v_payload->>'empty_generation' = '' then
    raise exception using errcode='P0001', message='INVALID_ARGUMENT';
  end if;
  for v_entry in select * from pg_catalog.jsonb_each(v_payload->'purged_revisions') order by key loop
    if v_entry.key !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or pg_catalog.jsonb_typeof(v_entry.value) <> 'number'
       or v_entry.value::text !~ '^[1-9][0-9]*$'
       or (v_entry.value::text)::numeric > 9223372036854775807 then
      raise exception using errcode='P0001', message='INVALID_ARGUMENT';
    end if;
    if v_previous->'purged_revisions'->v_entry.key = v_entry.value then continue; end if;
    select * into v_document from public.documents where document_id=v_entry.key::uuid for update;
    if not found or v_document.project_id <> p_project_id or not v_document.is_deleted
       or v_document.relative_path like '__antigravity__/%' or v_document.revision <> (v_entry.value::text)::bigint then
      raise exception using errcode='P0001', message='REVISION_CONFLICT';
    end if;
  end loop;
  select writer_device_id into v_device from public.sync_batches where batch_id=(p_intent->>'batch_id')::uuid and project_id=p_project_id and writer_user_id=p_user_id;
  if not found then raise exception using errcode='P0001', message='INVALID_ARGUMENT'; end if;
  v_revision := v_base+1;
  if v_base=0 then
    insert into public.documents(document_id,project_id,relative_path,content,revision,created_by,updated_by)
    values(v_id,p_project_id,v_path,v_content,v_revision,p_user_id,p_user_id);
  end if;
  insert into public.document_versions(document_id,project_id,revision,base_revision,operation_id,device_id,operation_kind,relative_path,content,content_hash,is_deleted,created_by)
  values(v_id,p_project_id,v_revision,v_base,(p_intent->>'operation_id')::uuid,v_device,
    case when v_base=0 then 'create' else 'update' end,v_path,v_content,private.content_sha256(v_content),false,p_user_id)
  returning version_id into v_version;
  update public.documents set content=v_content,revision=v_revision,current_version_id=v_version,updated_by=p_user_id,updated_at=v_now where document_id=v_id;
  return v_revision;
end;
$$;
revoke all on function private.apply_contract_trash_purge(uuid,uuid,jsonb) from public,anon,authenticated;

create or replace function private.apply_structure_intent(
  p_project_id uuid,
  p_user_id uuid,
  p_intent jsonb
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entity_kind text := p_intent->>'entity_kind';
  v_intent_kind text := p_intent->>'intent_kind';
  v_entity_id uuid := (p_intent->>'entity_id')::uuid;
  v_base_revision bigint := (p_intent->>'base_revision')::bigint;
  v_payload jsonb := p_intent->'payload';
  v_folder public.folders%rowtype;
  v_folder_exists boolean;
  v_parent_id uuid;
  v_name text;
  v_storage_key bytea;
  v_is_deleted boolean;
  v_revision bigint;
  v_children uuid[];
  v_child_text text;
  v_child uuid;
  v_resolution_count integer;
  v_tree public.tree_orders%rowtype;
begin
  if v_entity_kind = 'trash_purge' then
    return private.apply_contract_trash_purge(p_project_id,p_user_id,p_intent);
  end if;
  if v_entity_kind = 'folder' then
    select * into v_folder
    from public.folders
    where folder_id = v_entity_id
    for update;
    v_folder_exists := found;

    if v_base_revision = 0 then
      if v_folder_exists then
        raise exception using errcode = 'P0001', message = 'FOLDER_ALREADY_EXISTS';
      end if;
      if v_intent_kind not in ('ensure', 'create')
         or not (v_payload ? 'name') then
        raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
      end if;
      v_name := v_payload->>'name';
      v_parent_id := case
        when v_payload ? 'parent_folder_id' then (v_payload->>'parent_folder_id')::uuid
        else null
      end;
      v_is_deleted := false;
      v_revision := 1;
    else
      if not v_folder_exists or v_folder.project_id <> p_project_id then
        raise exception using errcode = 'P0001', message = 'FOLDER_NOT_FOUND';
      end if;
      if v_folder.revision <> v_base_revision then
        raise exception using errcode = 'P0001', message = 'REVISION_CONFLICT';
      end if;
      v_name := v_folder.name;
      v_parent_id := v_folder.parent_folder_id;
      v_is_deleted := v_folder.is_deleted;
      case v_intent_kind
        when 'rename' then
          if not (v_payload ? 'name') then
            raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
          end if;
          v_name := v_payload->>'name';
        when 'move' then
          if not (v_payload ? 'parent_folder_id') then
            raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
          end if;
          v_parent_id := (v_payload->>'parent_folder_id')::uuid;
        when 'delete' then
          v_is_deleted := true;
        when 'restore' then
          v_is_deleted := false;
          if v_payload ? 'name' then v_name := v_payload->>'name'; end if;
          if v_payload ? 'parent_folder_id' then
            v_parent_id := (v_payload->>'parent_folder_id')::uuid;
          end if;
        when 'ensure', 'update' then
          if v_payload ? 'name' then v_name := v_payload->>'name'; end if;
          if v_payload ? 'parent_folder_id' then
            v_parent_id := (v_payload->>'parent_folder_id')::uuid;
          end if;
        else
          raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
      end case;
      v_revision := v_folder.revision + 1;
    end if;

    if v_parent_id = v_entity_id then
      raise exception using errcode = 'P0001', message = 'PARENT_CYCLE';
    end if;
    if v_parent_id is not null then
      if not exists (
        select 1 from public.folders parent
        where parent.folder_id = v_parent_id
          and parent.project_id = p_project_id
          and not parent.is_deleted
      ) then
        raise exception using errcode = 'P0001', message = 'FOLDER_NOT_FOUND';
      end if;
      if exists (
        with recursive ancestors as (
          select folder_id, parent_folder_id
          from public.folders
          where folder_id = v_parent_id and project_id = p_project_id
          union all
          select parent.folder_id, parent.parent_folder_id
          from public.folders parent
          join ancestors child on parent.folder_id = child.parent_folder_id
          where parent.project_id = p_project_id
        )
        select 1 from ancestors where folder_id = v_entity_id
      ) then
        raise exception using errcode = 'P0001', message = 'PARENT_CYCLE';
      end if;
    end if;
    if v_is_deleted and (
      exists (
        select 1 from public.folders child
        where child.project_id = p_project_id
          and child.parent_folder_id = v_entity_id
          and not child.is_deleted
      )
      or exists (
        select 1 from public.documents document
        where document.project_id = p_project_id
          and document.parent_folder_id = v_entity_id
          and not document.is_deleted
      )
    ) then
      raise exception using errcode = 'P0001', message = 'FOLDER_NOT_EMPTY';
    end if;

    v_storage_key := private.storage_name_v1(v_name);
    if not v_is_deleted and (
      exists (
        select 1 from public.folders sibling
        where sibling.project_id = p_project_id
          and sibling.parent_folder_id is not distinct from v_parent_id
          and sibling.folder_id <> v_entity_id
          and not sibling.is_deleted
          and sibling.storage_name_key = v_storage_key
      )
      or exists (
        select 1 from public.documents sibling
        where sibling.project_id = p_project_id
          and sibling.parent_folder_id is not distinct from v_parent_id
          and sibling.document_id <> v_entity_id
          and not sibling.is_deleted
          and sibling.storage_name_key = v_storage_key
      )
    ) then
      raise exception using errcode = 'P0001', message = 'PATH_CONFLICT';
    end if;

    if v_folder_exists then
      update public.folders
      set parent_folder_id = v_parent_id,
          name = v_name,
          storage_name_key = v_storage_key,
          revision = v_revision,
          is_deleted = v_is_deleted,
          deleted_at = case when v_is_deleted then pg_catalog.transaction_timestamp() else null end,
          updated_by = p_user_id,
          updated_at = pg_catalog.transaction_timestamp()
      where folder_id = v_entity_id;
    else
      insert into public.folders (
        folder_id, project_id, parent_folder_id, name, storage_name_key,
        revision, is_deleted, deleted_at, created_by, updated_by
      ) values (
        v_entity_id, p_project_id, v_parent_id, v_name, v_storage_key,
        v_revision, false, null, p_user_id, p_user_id
      );
    end if;
    return v_revision;
  end if;

  if v_entity_kind = 'document' then
    if v_intent_kind not in ('rename', 'move') then
      raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
    end if;
    declare
      v_document public.documents%rowtype;
      v_document_name text;
      v_document_parent uuid;
      v_document_storage_key bytea;
      v_document_structure_revision bigint;
      v_document_path text;
    begin
      select * into v_document
      from public.documents
      where document_id = v_entity_id
      for update;
      if not found or v_document.project_id <> p_project_id or v_document.is_deleted then
        raise exception using errcode = 'P0001', message = 'DOCUMENT_NOT_FOUND';
      end if;
      if v_document.name is null or v_document.structure_revision is null then
        raise exception using errcode = 'P0001', message = 'INVARIANT_VIOLATION';
      end if;
      if v_document.structure_revision <> v_base_revision then
        raise exception using errcode = 'P0001', message = 'STRUCTURE_REVISION_CONFLICT';
      end if;
      v_document_name := v_document.name;
      v_document_parent := v_document.parent_folder_id;
      if v_intent_kind = 'rename' then
        if not (v_payload ? 'name') then
          raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
        end if;
        v_document_name := v_payload->>'name';
      else
        if not (v_payload ? 'parent_folder_id') then
          raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
        end if;
        v_document_parent := case when v_payload->'parent_folder_id' = 'null'::jsonb
          then null else (v_payload->>'parent_folder_id')::uuid end;
      end if;
      v_document_storage_key := private.storage_name_v1(v_document_name);
      v_document_path := private.document_relative_path(
        p_project_id, v_document_parent, v_document_name
      );
      if exists (
        select 1 from public.folders sibling
        where sibling.project_id = p_project_id
          and sibling.parent_folder_id is not distinct from v_document_parent
          and not sibling.is_deleted
          and sibling.storage_name_key = v_document_storage_key
      ) or exists (
        select 1 from public.documents sibling
        where sibling.project_id = p_project_id
          and sibling.parent_folder_id is not distinct from v_document_parent
          and sibling.document_id <> v_entity_id
          and not sibling.is_deleted
          and sibling.storage_name_key = v_document_storage_key
      ) then
        raise exception using errcode = 'P0001', message = 'PATH_CONFLICT';
      end if;
      v_document_structure_revision := v_document.structure_revision + 1;
      update public.documents
      set name = v_document_name,
          parent_folder_id = v_document_parent,
          storage_name_key = v_document_storage_key,
          relative_path = v_document_path,
          structure_revision = v_document_structure_revision,
          updated_by = p_user_id,
          updated_at = pg_catalog.transaction_timestamp()
      where document_id = v_entity_id;
      return v_document_structure_revision;
    end;
  end if;

  if v_entity_kind = 'tree_order' then
    if v_intent_kind <> 'reorder'
       or pg_catalog.jsonb_typeof(v_payload->'children') <> 'array' then
      raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
    end if;
    select coalesce(pg_catalog.array_agg(value::uuid order by ordinality), '{}'::uuid[])
    into v_children
    from pg_catalog.jsonb_array_elements_text(v_payload->'children') with ordinality;
    if pg_catalog.cardinality(v_children) <>
       (select count(distinct value) from pg_catalog.unnest(v_children) value) then
      raise exception using errcode = 'P0001', message = 'TREE_REFERENCE_DUPLICATED';
    end if;
    foreach v_child in array v_children loop
      select count(*) into v_resolution_count
      from (
        select folder_id as entity_id
        from public.folders
        where project_id = p_project_id and folder_id = v_child and not is_deleted
        union all
        select document_id
        from public.documents
        where project_id = p_project_id and document_id = v_child and not is_deleted
      ) resolved;
      if v_resolution_count = 0 then
        raise exception using errcode = 'P0001', message = 'TREE_REFERENCE_NOT_FOUND';
      elsif v_resolution_count > 1 then
        raise exception using errcode = 'P0001', message = 'TREE_REFERENCE_DUPLICATED';
      end if;
    end loop;

    select * into v_tree
    from public.tree_orders
    where tree_order_id = v_entity_id
    for update;
    if v_base_revision = 0 then
      if found then
        raise exception using errcode = 'P0001', message = 'OPERATION_ID_REUSED';
      end if;
      v_revision := 1;
      insert into public.tree_orders (
        tree_order_id, project_id, parent_folder_id, children, revision,
        created_by, updated_by
      ) values (
        v_entity_id, p_project_id,
        case when v_payload ? 'parent_folder_id'
          then (v_payload->>'parent_folder_id')::uuid else null end,
        v_children, v_revision, p_user_id, p_user_id
      );
    else
      if not found or v_tree.project_id <> p_project_id then
        raise exception using errcode = 'P0001', message = 'TREE_REFERENCE_NOT_FOUND';
      end if;
      if v_tree.revision <> v_base_revision then
        raise exception using errcode = 'P0001', message = 'REVISION_CONFLICT';
      end if;
      v_revision := v_tree.revision + 1;
      update public.tree_orders
      set children = v_children,
          revision = v_revision,
          updated_by = p_user_id,
          updated_at = pg_catalog.transaction_timestamp()
      where tree_order_id = v_entity_id;
    end if;
    return v_revision;
  end if;

  raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
end;
$$;
revoke all on function private.apply_structure_intent(uuid,uuid,jsonb) from public,anon,authenticated;

-- 표식도 계약 operation 이력과 정확히 결합된 version만 허용한다.
create or replace function private.enforce_document_write_boundary()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_mode text := 'LEGACY';
begin
  select project_sync_mode into v_mode
  from public.project_sync_settings
  where project_id = new.project_id;
  if not found then v_mode := 'LEGACY'; end if;

  if v_mode <> 'LEGACY' and not exists (
    select 1
    from public.sync_operations operation
    join public.sync_batches batch on batch.batch_id = operation.batch_id
    where operation.operation_id = new.operation_id
      and operation.project_id = new.project_id
      and (operation.entity_kind = 'document' or (
        operation.entity_kind = 'trash_purge' and operation.intent_kind = 'update'
        and operation.entity_id = new.document_id
        and new.relative_path = '__antigravity__/trash-purge.json'
        and not new.is_deleted
        and operation.base_revision = new.base_revision
        and new.revision = new.base_revision + 1
        and operation.payload->>'content' = new.content
      ))
      and operation.provenance_kind = 'CONTRACT_BATCH'
      and batch.sync_protocol_version = 3
      and batch.canonical_contract_sha256 =
        '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670'
  ) then
    raise exception using errcode = 'P0001', message = 'PROTOCOL_TOO_OLD';
  end if;
  return new;
end;
$$;
revoke all on function private.enforce_document_write_boundary() from public,anon,authenticated;
commit;
