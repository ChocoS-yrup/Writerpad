begin;

-- WriterPad sync-contract 0.1.0 server RPCs.
-- contract_git_commit: 45d18cff62cc48e29d0e6efcfc634fec96150198
-- contract_content_commit: 7f05f32dd385ce0e1922b88d688742fca2a503fa
-- canonical bytes/SHA-256: 19473 / fae86b4e6385ee37fbeb99f9256194ec319b64bfda92974ce90a3eb70d2e7a46

create or replace function private.rfc8785_canonical_json(p_value jsonb)
returns text
language plpgsql
immutable
strict
set search_path = ''
as $$
declare
  v_type text := pg_catalog.jsonb_typeof(p_value);
  v_result text;
begin
  case v_type
    when 'null' then
      return 'null';
    when 'boolean' then
      return p_value::text;
    when 'string' then
      return pg_catalog.to_jsonb(p_value #>> '{}')::text;
    when 'number' then
      -- Stage 7 structural payloads contain JSON integers only. Rejecting
      -- fractions avoids pretending jsonb numeric output is ECMAScript number
      -- serialization for values outside the released wire schema.
      if p_value::text !~ '^-?(0|[1-9][0-9]*)$' then
        raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
      end if;
      return p_value::text;
    when 'array' then
      select '[' || coalesce(pg_catalog.string_agg(
        private.rfc8785_canonical_json(value), ',' order by ordinality
      ), '') || ']'
      into v_result
      from pg_catalog.jsonb_array_elements(p_value) with ordinality;
      return v_result;
    when 'object' then
      if exists (
        select 1 from pg_catalog.jsonb_object_keys(p_value) key
        where key !~ '^[A-Za-z_][A-Za-z0-9_]*$'
      ) then
        raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
      end if;
      select '{' || coalesce(pg_catalog.string_agg(
        pg_catalog.to_jsonb(key)::text || ':' ||
          private.rfc8785_canonical_json(value),
        ',' order by key collate "C"
      ), '') || '}'
      into v_result
      from pg_catalog.jsonb_each(p_value);
      return v_result;
    else
      raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end case;
end;
$$;

create or replace function private.jsonb_rfc8785_sha256(p_value jsonb)
returns text
language sql
immutable
strict
set search_path = ''
as $$
  select pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(private.rfc8785_canonical_json(p_value), 'UTF8'),
      'sha256'
    ),
    'hex'
  );
$$;

create or replace function private.atomic_failure(
  p_batch_id uuid,
  p_batch_payload_sha256 text,
  p_code text,
  p_message text,
  p_failed_sequence integer default null
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'kind', 'atomic_structure_commit_failure',
    'batch_id', p_batch_id,
    'batch_payload_sha256', p_batch_payload_sha256,
    'status', 'rejected',
    'applied', false,
    'error', pg_catalog.jsonb_build_object(
      'code', p_code,
      'message', p_message,
      'failed_sequence', p_failed_sequence
    ),
    'results', '[]'::jsonb
  );
$$;

create or replace function private.storage_name_v1_result(p_name text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_key bytea;
begin
  v_key := private.storage_name_v1(p_name);
  return pg_catalog.jsonb_build_object(
    'valid', true,
    'normalized', pg_catalog.convert_from(v_key, 'UTF8'),
    'utf8_hex', pg_catalog.encode(v_key, 'hex')
  );
exception
  when sqlstate 'P0001' then
    return pg_catalog.jsonb_build_object('valid', false, 'error_code', sqlerrm);
end;
$$;

do $storage_vectors$
declare
  v_vector record;
  v_actual jsonb;
begin
  for v_vector in
    select * from (values
      ('SN-001', 'Résumé', true, 'résumé', '72c3a973756dc3a9', null),
      ('SN-002', U&'Re\0301sume\0301', true, 'résumé', '72c3a973756dc3a9', null),
      ('SN-003', 'FILE.TXT', true, 'file.txt', '66696c652e747874', null),
      ('SN-004', 'File. ', true, 'file', '66696c65', null),
      ('SN-005', '폴더', true, '폴더', 'ed8fb4eb8d94', null),
      ('SN-006', U&'\0130', true, U&'i\0307', '69cc87', null),
      ('SN-007', 'Straße', true, 'strasse', '73747261737365', null),
      ('SN-008', ' leading', true, ' leading', '206c656164696e67', null),
      ('SN-009', U&'A\00A0B', true, 'a b', '612062', null),
      ('SN-010', 'ＡＢＣ', true, 'abc', '616263', null),
      ('SN-011', 'CON.txt', false, null, null, 'STORAGE_NAME_RESERVED'),
      ('SN-012', 'folder/name', false, null, null, 'STORAGE_NAME_INVALID'),
      ('SN-013', E'folder\\name', false, null, null, 'STORAGE_NAME_INVALID'),
      ('SN-014', '. ', false, null, null, 'STORAGE_NAME_INVALID'),
      ('SN-015', '', false, null, null, 'STORAGE_NAME_INVALID')
    ) as vector(vector_id, input, valid, normalized, utf8_hex, error_code)
  loop
    v_actual := private.storage_name_v1_result(v_vector.input);
    if (v_actual->>'valid')::boolean is distinct from v_vector.valid
       or (v_vector.valid and (
         v_actual->>'normalized' is distinct from v_vector.normalized
         or v_actual->>'utf8_hex' is distinct from v_vector.utf8_hex
       ))
       or (not v_vector.valid and
         v_actual->>'error_code' is distinct from v_vector.error_code) then
      raise exception using
        errcode = 'P0001',
        message = 'STORAGE_NAME_VECTOR_MISMATCH',
        detail = v_vector.vector_id || ': ' || v_actual::text;
    end if;
  end loop;
end;
$storage_vectors$;

create or replace function private.append_operation_event(
  p_operation_id uuid,
  p_event_id uuid,
  p_event_type text,
  p_error_code text default null,
  p_blocking_operation_id uuid default null,
  p_detail jsonb default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing public.sync_operation_events%rowtype;
  v_sequence integer;
  v_latest_type text;
begin
  perform 1
  from public.sync_operations
  where operation_id = p_operation_id
  for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  select * into v_existing
  from public.sync_operation_events
  where event_id = p_event_id;
  if found then
    if v_existing.operation_id = p_operation_id
       and v_existing.event_type = p_event_type
       and v_existing.error_code is not distinct from p_error_code
       and v_existing.blocking_operation_id is not distinct from p_blocking_operation_id
       and v_existing.detail is not distinct from p_detail then
      return v_existing.event_sequence;
    end if;
    raise exception using errcode = 'P0001', message = 'EVENT_ID_REUSED';
  end if;

  select event_type into v_latest_type
  from public.sync_operation_events
  where operation_id = p_operation_id
  order by event_sequence desc
  limit 1;
  if v_latest_type in ('committed', 'replayed', 'cancel_requested', 'superseded') then
    raise exception using errcode = 'P0001', message = 'OPERATION_TERMINAL';
  end if;

  select coalesce(max(event_sequence), 0) + 1 into v_sequence
  from public.sync_operation_events
  where operation_id = p_operation_id;

  insert into public.sync_operation_events (
    event_id, operation_id, event_sequence, event_type,
    error_code, blocking_operation_id, detail
  ) values (
    p_event_id, p_operation_id, v_sequence, p_event_type,
    p_error_code, p_blocking_operation_id, p_detail
  );
  return v_sequence;
end;
$$;

create or replace function private.validate_contract_request(
  p_user_id uuid,
  p_project_id uuid,
  p_project_sync_mode text,
  p_migration_epoch integer,
  p_batch jsonb,
  p_ordered_intents jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_allowlist private.sync_contract_allowlist%rowtype;
  v_settings public.project_sync_settings%rowtype;
  v_actual_mode text := 'LEGACY';
  v_actual_epoch integer := 0;
  v_capabilities text[];
  v_capability_count integer;
  v_distinct_capability_count integer;
  v_required text[] := array[
    'folders_authoritative', 'tree_order_ids', 'tombstones',
    'immutable_batch_contract_metadata', 'operation_attempt_history',
    'operation_state_events', 'storage_name_v1'
  ]::text[];
  v_intent jsonb;
  v_sequence integer := 0;
  v_seen_operations uuid[] := '{}'::uuid[];
  v_writer_device_id uuid;
  v_active_writer_device_id uuid;
begin
  if p_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_project_id is null
     or p_project_sync_mode not in ('LEGACY', 'MIGRATING', 'ID_BASED')
     or p_migration_epoch is null
     or pg_catalog.jsonb_typeof(p_batch) <> 'object'
     or pg_catalog.jsonb_typeof(p_ordered_intents) <> 'array'
     or pg_catalog.jsonb_array_length(p_ordered_intents) = 0 then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;
  if not private.has_project_role(p_project_id, p_user_id, 'editor') then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  select * into v_settings
  from public.project_sync_settings
  where project_id = p_project_id;
  if found then
    v_actual_mode := v_settings.project_sync_mode;
    v_actual_epoch := v_settings.migration_epoch;
  end if;
  if v_actual_mode <> p_project_sync_mode then
    raise exception using errcode = 'P0001', message = 'PROJECT_MIGRATING';
  end if;
  if v_actual_epoch <> p_migration_epoch then
    raise exception using errcode = 'P0001', message = 'STALE_MIGRATION_EPOCH';
  end if;

  if p_batch->>'contract_version' <> '0.1.0' then
    raise exception using errcode = 'P0001', message = 'CONTRACT_DIGEST_MISMATCH';
  end if;
  if p_batch->>'canonical_contract_sha256' <>
     'fae86b4e6385ee37fbeb99f9256194ec319b64bfda92974ce90a3eb70d2e7a46' then
    if exists (
      select 1 from private.sync_contract_allowlist
      where contract_version = p_batch->>'contract_version'
    ) then
      raise exception using errcode = 'P0001', message = 'CONTRACT_DIGEST_MISMATCH';
    end if;
    raise exception using errcode = 'P0001', message = 'CONTRACT_NOT_ALLOWED';
  end if;

  select * into v_allowlist
  from private.sync_contract_allowlist
  where canonical_contract_sha256 = p_batch->>'canonical_contract_sha256'
    and enabled
    and revoked_at is null
    and valid_from <= pg_catalog.transaction_timestamp();
  if not found then
    raise exception using errcode = 'P0001', message = 'CONTRACT_NOT_ALLOWED';
  end if;
  if (p_batch->>'sync_protocol_version')::integer <> 3
     or not ((p_batch->>'sync_protocol_version')::integer = any(v_allowlist.allowed_protocol_versions)) then
    raise exception using errcode = 'P0001', message = 'PROTOCOL_TOO_OLD';
  end if;

  if pg_catalog.jsonb_typeof(p_batch->'client_capabilities') <> 'array' then
    raise exception using errcode = 'P0001', message = 'CAPABILITY_MISMATCH';
  end if;
  select
    coalesce(pg_catalog.array_agg(value order by value), '{}'::text[]),
    count(*),
    count(distinct value)
  into v_capabilities, v_capability_count, v_distinct_capability_count
  from pg_catalog.jsonb_array_elements_text(p_batch->'client_capabilities');
  if v_capability_count <> v_distinct_capability_count
     or not (v_capabilities @> v_required)
     or not (v_capabilities <@ v_allowlist.allowed_client_capabilities) then
    raise exception using errcode = 'P0001', message = 'CAPABILITY_MISMATCH';
  end if;

  if p_batch->>'client_build_id' is null or p_batch->>'client_build_id' = '' then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;
  v_writer_device_id := (p_batch->>'writer_device_id')::uuid;
  if v_writer_device_id is null then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  if v_actual_mode in ('MIGRATING', 'ID_BASED') then
    if v_settings.contract_enforcement_started_at is null
       or v_settings.active_contract_sha256 <>
         'fae86b4e6385ee37fbeb99f9256194ec319b64bfda92974ce90a3eb70d2e7a46' then
      raise exception using errcode = 'P0001', message = 'CONTRACT_NOT_ALLOWED';
    end if;
  end if;
  if v_actual_mode = 'MIGRATING' then
    select started_by_device_id into v_active_writer_device_id
    from public.project_sync_migrations
    where project_id = p_project_id
      and migration_epoch = v_actual_epoch
      and completed_at is null;
    if not found or v_active_writer_device_id <> v_writer_device_id then
      raise exception using errcode = 'P0001', message = 'MIGRATION_LOCKED';
    end if;
  end if;

  if p_batch->>'batch_payload_sha256' <>
     private.jsonb_rfc8785_sha256(p_ordered_intents) then
    raise exception using errcode = 'P0001', message = 'CONTRACT_DIGEST_MISMATCH';
  end if;

  for v_intent in
    select value from pg_catalog.jsonb_array_elements(p_ordered_intents)
    order by (value->>'sequence')::integer
  loop
    v_sequence := v_sequence + 1;
    if (v_intent->>'sequence')::integer <> v_sequence
       or (v_intent->>'batch_id')::uuid <> (p_batch->>'batch_id')::uuid
       or (v_intent->>'base_revision')::bigint < 0
       or v_intent->>'entity_kind' not in ('project', 'folder', 'document', 'tree_order', 'trash_purge')
       or v_intent->>'intent_kind' not in ('ensure', 'create', 'update', 'rename', 'move', 'delete', 'restore', 'reorder', 'migrate')
       or pg_catalog.jsonb_typeof(v_intent->'payload') <> 'object'
       or v_intent->>'payload_sha256' <>
         private.jsonb_rfc8785_sha256(v_intent->'payload') then
      raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
    end if;
    if (v_intent->>'operation_id')::uuid = any(v_seen_operations) then
      raise exception using errcode = 'P0001', message = 'OPERATION_ID_REUSED';
    end if;
    v_seen_operations := pg_catalog.array_append(
      v_seen_operations, (v_intent->>'operation_id')::uuid
    );
    if v_intent ? 'supersedes_operation_id'
       and (
         (v_intent->>'supersedes_operation_id')::uuid = (v_intent->>'operation_id')::uuid
         or not exists (
           select 1 from public.sync_operations original
           where original.operation_id = (v_intent->>'supersedes_operation_id')::uuid
             and original.project_id = p_project_id
         )
       ) then
      raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
    end if;
  end loop;

  if v_sequence <> pg_catalog.jsonb_array_length(p_ordered_intents) then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;
end;
$$;

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

create or replace function public.atomic_structure_commit(p_request jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_project_id uuid;
  v_mode text;
  v_epoch integer;
  v_batch jsonb;
  v_intents jsonb;
  v_batch_id uuid;
  v_payload_sha text;
  v_request_sha text;
  v_existing_batch public.sync_batches%rowtype;
  v_existing_result public.sync_batch_results%rowtype;
  v_intent jsonb;
  v_response jsonb;
  v_results jsonb := '[]'::jsonb;
  v_result_revision bigint;
  v_failed_sequence integer;
  v_error_code text;
  v_error_message text;
  v_started_at timestamptz := pg_catalog.clock_timestamp();
  v_operation_id uuid;
  v_outcome text;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if pg_catalog.jsonb_typeof(p_request) <> 'object'
     or p_request->>'kind' <> 'atomic_structure_commit_request' then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  begin
    v_project_id := (p_request->>'project_id')::uuid;
    v_mode := p_request->>'project_sync_mode';
    v_epoch := (p_request->>'migration_epoch')::integer;
    v_batch := p_request->'batch';
    v_intents := p_request->'ordered_intents';
    v_batch_id := (v_batch->>'batch_id')::uuid;
    v_payload_sha := v_batch->>'batch_payload_sha256';
    v_request_sha := private.jsonb_rfc8785_sha256(p_request);
  exception when others then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('project:' || v_project_id::text, 0)
  );
  if not private.has_project_role(v_project_id, v_user_id, 'editor') then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  select * into v_existing_batch
  from public.sync_batches
  where batch_id = v_batch_id;
  if found then
    if v_existing_batch.project_id <> v_project_id
       or v_existing_batch.writer_user_id <> v_user_id
       or v_existing_batch.writer_device_id <> (v_batch->>'writer_device_id')::uuid
       or v_existing_batch.client_build_id <> v_batch->>'client_build_id'
       or v_existing_batch.sync_protocol_version <> (v_batch->>'sync_protocol_version')::integer
       or v_existing_batch.contract_version <> v_batch->>'contract_version'
       or v_existing_batch.canonical_contract_sha256 <> v_batch->>'canonical_contract_sha256'
       or v_existing_batch.batch_payload_sha256 <> v_payload_sha
       or v_existing_batch.project_sync_mode <> v_mode
       or v_existing_batch.migration_epoch <> v_epoch
       or v_existing_batch.request_sha256 <> v_request_sha then
      return private.atomic_failure(
        v_batch_id, v_payload_sha, 'BATCH_ID_REUSED',
        'batch_id already belongs to a different payload', null
      );
    end if;

    select * into v_existing_result
    from public.sync_batch_results
    where batch_id = v_batch_id;
    if not found then
      raise exception using errcode = 'P0001', message = 'INVARIANT_VIOLATION';
    end if;
    if v_existing_result.applied then
      return pg_catalog.jsonb_set(
        v_existing_result.response, '{status}', '"replayed"'::jsonb, false
      );
    end if;
    return v_existing_result.response;
  end if;

  begin
    perform private.validate_contract_request(
      v_user_id, v_project_id, v_mode, v_epoch, v_batch, v_intents
    );
  exception when sqlstate 'P0001' then
    return private.atomic_failure(v_batch_id, v_payload_sha, sqlerrm, sqlerrm, null);
  end;

  if exists (
    select 1
    from pg_catalog.jsonb_array_elements(v_intents) item
    join public.sync_operations existing
      on existing.operation_id = (item->>'operation_id')::uuid
  ) then
    return private.atomic_failure(
      v_batch_id, v_payload_sha, 'OPERATION_ID_REUSED',
      'operation_id already belongs to an immutable intent', null
    );
  end if;

  insert into public.sync_batches (
    batch_id, project_id, writer_user_id, writer_device_id, client_build_id,
    sync_protocol_version, contract_version, canonical_contract_sha256,
    client_capabilities, batch_payload_sha256, project_sync_mode,
    migration_epoch, request_sha256
  ) values (
    v_batch_id, v_project_id, v_user_id, (v_batch->>'writer_device_id')::uuid,
    v_batch->>'client_build_id', (v_batch->>'sync_protocol_version')::integer,
    v_batch->>'contract_version', v_batch->>'canonical_contract_sha256',
    array(select value from pg_catalog.jsonb_array_elements_text(v_batch->'client_capabilities') order by value),
    v_payload_sha, v_mode, v_epoch, v_request_sha
  );

  for v_intent in
    select value from pg_catalog.jsonb_array_elements(v_intents)
    order by (value->>'sequence')::integer
  loop
    v_operation_id := (v_intent->>'operation_id')::uuid;
    insert into public.sync_operations (
      operation_id, project_id, provenance_kind, batch_id, sequence,
      entity_kind, entity_id, intent_kind, base_revision, payload_sha256,
      payload, supersedes_operation_id, created_by
    ) values (
      v_operation_id, v_project_id, 'CONTRACT_BATCH', v_batch_id,
      (v_intent->>'sequence')::integer, v_intent->>'entity_kind',
      (v_intent->>'entity_id')::uuid, v_intent->>'intent_kind',
      (v_intent->>'base_revision')::bigint, v_intent->>'payload_sha256',
      v_intent->'payload',
      case when v_intent ? 'supersedes_operation_id'
        then (v_intent->>'supersedes_operation_id')::uuid else null end,
      v_user_id
    );
    perform private.append_operation_event(
      v_operation_id, pg_catalog.gen_random_uuid(), 'enqueued'
    );
    perform private.append_operation_event(
      v_operation_id, pg_catalog.gen_random_uuid(), 'dispatch_started'
    );
  end loop;

  for v_intent in
    select value from pg_catalog.jsonb_array_elements(v_intents)
    where value ? 'supersedes_operation_id'
    order by (value->>'sequence')::integer
  loop
    perform private.append_operation_event(
      (v_intent->>'supersedes_operation_id')::uuid,
      pg_catalog.gen_random_uuid(), 'superseded', null,
      (v_intent->>'operation_id')::uuid,
      pg_catalog.jsonb_build_object('successor_operation_id', v_intent->>'operation_id')
    );
  end loop;

  begin
    for v_intent in
      select value from pg_catalog.jsonb_array_elements(v_intents)
      order by (value->>'sequence')::integer
    loop
      v_failed_sequence := (v_intent->>'sequence')::integer;
      v_result_revision := private.apply_structure_intent(
        v_project_id, v_user_id, v_intent
      );
      v_results := v_results || pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'sequence', v_failed_sequence,
          'operation_id', v_intent->>'operation_id',
          'entity_id', v_intent->>'entity_id',
          'result_revision', v_result_revision
        )
      );
    end loop;
  exception when sqlstate 'P0001' then
    v_error_code := sqlerrm;
    v_error_message := sqlerrm;
    v_results := '[]'::jsonb;
  end;

  if v_error_code is not null then
    v_response := private.atomic_failure(
      v_batch_id, v_payload_sha, v_error_code, v_error_message, v_failed_sequence
    );
    for v_intent in
      select value from pg_catalog.jsonb_array_elements(v_intents)
      order by (value->>'sequence')::integer
    loop
      v_operation_id := (v_intent->>'operation_id')::uuid;
      v_outcome := case
        when (v_intent->>'sequence')::integer = v_failed_sequence
             and v_error_code = 'REVISION_CONFLICT' then 'conflict'
        else 'blocked'
      end;
      perform private.append_operation_event(
        v_operation_id, pg_catalog.gen_random_uuid(),
        case when v_outcome = 'conflict' then 'conflict_detected' else 'blocked' end,
        v_error_code, null,
        pg_catalog.jsonb_build_object('failed_sequence', v_failed_sequence)
      );
      insert into public.sync_operation_attempts (
        attempt_id, operation_id, attempt_number, started_at, finished_at,
        rpc_name, outcome, request_sha256, response_sha256, error_code,
        error_detail
      ) values (
        pg_catalog.gen_random_uuid(), v_operation_id, 1, v_started_at,
        pg_catalog.clock_timestamp(), 'atomic_structure_commit', v_outcome,
        v_request_sha, private.jsonb_rfc8785_sha256(v_response), v_error_code,
        pg_catalog.jsonb_build_object('failed_sequence', v_failed_sequence)
      );
    end loop;
    insert into public.sync_batch_results (
      batch_id, response, response_sha256, applied
    ) values (
      v_batch_id, v_response, private.jsonb_rfc8785_sha256(v_response), false
    );
    return v_response;
  end if;

  v_response := pg_catalog.jsonb_build_object(
    'kind', 'atomic_structure_commit_success',
    'batch_id', v_batch_id,
    'batch_payload_sha256', v_payload_sha,
    'status', 'committed',
    'applied', true,
    'results', v_results
  );
  for v_intent in
    select value from pg_catalog.jsonb_array_elements(v_intents)
    order by (value->>'sequence')::integer
  loop
    v_operation_id := (v_intent->>'operation_id')::uuid;
    select (result->>'result_revision')::bigint into v_result_revision
    from pg_catalog.jsonb_array_elements(v_results) result
    where result->>'operation_id' = v_operation_id::text;
    perform private.append_operation_event(
      v_operation_id, pg_catalog.gen_random_uuid(), 'committed'
    );
    insert into public.sync_operation_attempts (
      attempt_id, operation_id, attempt_number, started_at, finished_at,
      rpc_name, outcome, request_sha256, response_sha256, result_revision
    ) values (
      pg_catalog.gen_random_uuid(), v_operation_id, 1, v_started_at,
      pg_catalog.clock_timestamp(), 'atomic_structure_commit', 'committed',
      v_request_sha, private.jsonb_rfc8785_sha256(v_response), v_result_revision
    );
  end loop;
  insert into public.sync_batch_results (
    batch_id, response, response_sha256, applied
  ) values (
    v_batch_id, v_response, private.jsonb_rfc8785_sha256(v_response), true
  );
  return v_response;
end;
$$;

create or replace function public.cancel_sync_operation(
  p_operation_id uuid,
  p_cancel_event_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_operation public.sync_operations%rowtype;
  v_event public.sync_operation_events%rowtype;
  v_state text;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_operation_id is null or p_cancel_event_id is null then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  select * into v_operation
  from public.sync_operations
  where operation_id = p_operation_id
  for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;
  if not private.has_project_role(v_operation.project_id, v_user_id, 'editor') then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  select * into v_event
  from public.sync_operation_events
  where event_id = p_cancel_event_id;
  if found then
    if v_event.operation_id = p_operation_id
       and v_event.event_type = 'cancel_requested' then
      return pg_catalog.jsonb_build_object(
        'operation_id', p_operation_id,
        'status', 'already_cancelled',
        'event_id', p_cancel_event_id
      );
    end if;
    raise exception using errcode = 'P0001', message = 'EVENT_ID_REUSED';
  end if;

  select state into v_state
  from public.sync_operation_states
  where operation_id = p_operation_id;
  if v_state = 'completed' then
    raise exception using errcode = 'P0001', message = 'OPERATION_TERMINAL';
  end if;
  if v_state = 'cancelled' then
    return pg_catalog.jsonb_build_object(
      'operation_id', p_operation_id,
      'status', 'already_cancelled'
    );
  end if;

  perform private.append_operation_event(
    p_operation_id, p_cancel_event_id, 'cancel_requested'
  );
  return pg_catalog.jsonb_build_object(
    'operation_id', p_operation_id,
    'status', 'cancelled',
    'event_id', p_cancel_event_id
  );
end;
$$;

create or replace function public.validate_project_sync_migration(p_project_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_issues jsonb := '[]'::jsonb;
  v_count bigint;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if not private.has_project_role(p_project_id, v_user_id, 'editor') then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  select count(*) into v_count
  from public.folders folder
  where folder.project_id = p_project_id
    and not folder.is_deleted
    and not (private.storage_name_v1_result(folder.name)->>'valid')::boolean;
  if v_count > 0 then
    v_issues := v_issues || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'STORAGE_NAME_INVALID', 'count', v_count)
    );
  end if;

  select count(*) into v_count
  from public.folders child
  left join public.folders parent
    on parent.folder_id = child.parent_folder_id
   and parent.project_id = child.project_id
   and not parent.is_deleted
  where child.project_id = p_project_id
    and not child.is_deleted
    and child.parent_folder_id is not null
    and parent.folder_id is null;
  if v_count > 0 then
    v_issues := v_issues || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'FOLDER_NOT_FOUND', 'count', v_count)
    );
  end if;

  select count(*) into v_count
  from (
    select parent_folder_id, private.storage_name_v1(name) as collision_key
    from public.folders
    where project_id = p_project_id
      and not is_deleted
      and (private.storage_name_v1_result(name)->>'valid')::boolean
  ) names
  group by parent_folder_id, collision_key
  having count(*) > 1
  limit 1;
  if found then
    v_issues := v_issues || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'PATH_CONFLICT', 'count', v_count)
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'project_id', p_project_id,
    'valid', pg_catalog.jsonb_array_length(v_issues) = 0,
    'issues', v_issues
  );
end;
$$;

create or replace function public.begin_project_sync_migration(
  p_project_id uuid,
  p_writer_device_id uuid,
  p_target_contract_sha256 text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_owner_id uuid;
  v_settings public.project_sync_settings%rowtype;
  v_epoch integer;
  v_migration_id uuid;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_project_id is null or p_writer_device_id is null then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;
  if p_target_contract_sha256 <>
     'fae86b4e6385ee37fbeb99f9256194ec319b64bfda92974ce90a3eb70d2e7a46'
     or not exists (
       select 1 from private.sync_contract_allowlist
       where canonical_contract_sha256 = p_target_contract_sha256
         and enabled and revoked_at is null
     ) then
    raise exception using errcode = 'P0001', message = 'CONTRACT_NOT_ALLOWED';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('project:' || p_project_id::text, 0)
  );
  select owner_id into v_owner_id
  from public.projects
  where project_id = p_project_id
  for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;
  if v_owner_id <> v_user_id then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  select * into v_settings
  from public.project_sync_settings
  where project_id = p_project_id
  for update;
  if found and v_settings.project_sync_mode <> 'LEGACY' then
    raise exception using errcode = 'P0001', message = 'MIGRATION_LOCKED';
  end if;
  if exists (
    select 1 from public.project_sync_migrations
    where project_id = p_project_id and completed_at is null
  ) then
    raise exception using errcode = 'P0001', message = 'MIGRATION_LOCKED';
  end if;

  v_epoch := 1;
  insert into public.project_sync_settings (
    project_id, project_sync_mode, migration_epoch,
    contract_enforcement_started_at, active_contract_sha256
  ) values (
    p_project_id, 'MIGRATING', v_epoch,
    pg_catalog.transaction_timestamp(), p_target_contract_sha256
  )
  on conflict (project_id) do update
  set project_sync_mode = 'MIGRATING',
      migration_epoch = excluded.migration_epoch,
      contract_enforcement_started_at = excluded.contract_enforcement_started_at,
      active_contract_sha256 = excluded.active_contract_sha256,
      updated_at = pg_catalog.transaction_timestamp();

  insert into public.project_sync_migrations (
    project_id, migration_epoch, source_mode, target_mode,
    started_by_user_id, started_by_device_id,
    source_contract_sha256, target_contract_sha256
  ) values (
    p_project_id, v_epoch, 'LEGACY', 'MIGRATING',
    v_user_id, p_writer_device_id, null, p_target_contract_sha256
  ) returning migration_id into v_migration_id;

  return pg_catalog.jsonb_build_object(
    'status', 'migrating',
    'project_id', p_project_id,
    'migration_id', v_migration_id,
    'migration_epoch', v_epoch,
    'contract_enforcement_started_at', pg_catalog.transaction_timestamp()
  );
end;
$$;

create or replace function public.complete_project_sync_migration(
  p_project_id uuid,
  p_writer_device_id uuid,
  p_migration_epoch integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_settings public.project_sync_settings%rowtype;
  v_migration public.project_sync_migrations%rowtype;
  v_validation jsonb;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('project:' || p_project_id::text, 0)
  );
  if not private.has_project_role(p_project_id, v_user_id, 'owner') then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  select * into v_settings
  from public.project_sync_settings
  where project_id = p_project_id
  for update;
  if not found or v_settings.project_sync_mode <> 'MIGRATING' then
    raise exception using errcode = 'P0001', message = 'STALE_MIGRATION_EPOCH';
  end if;
  if v_settings.migration_epoch <> p_migration_epoch then
    raise exception using errcode = 'P0001', message = 'STALE_MIGRATION_EPOCH';
  end if;

  select * into v_migration
  from public.project_sync_migrations
  where project_id = p_project_id
    and migration_epoch = p_migration_epoch
    and completed_at is null
  for update;
  if not found or v_migration.started_by_device_id <> p_writer_device_id then
    raise exception using errcode = 'P0001', message = 'MIGRATION_LOCKED';
  end if;

  v_validation := public.validate_project_sync_migration(p_project_id);
  update public.project_sync_migrations
  set validation_result = v_validation
  where migration_id = v_migration.migration_id;
  if not (v_validation->>'valid')::boolean then
    return pg_catalog.jsonb_build_object(
      'status', 'validation_failed',
      'project_id', p_project_id,
      'migration_epoch', p_migration_epoch,
      'validation', v_validation
    );
  end if;

  update public.folders
  set storage_name_key = private.storage_name_v1(name)
  where project_id = p_project_id and not is_deleted;

  update public.project_sync_settings
  set project_sync_mode = 'ID_BASED',
      updated_at = pg_catalog.transaction_timestamp()
  where project_id = p_project_id;

  update public.project_sync_migrations
  set target_mode = 'ID_BASED',
      completed_at = pg_catalog.transaction_timestamp(),
      completed_by_user_id = v_user_id
  where migration_id = v_migration.migration_id;

  return pg_catalog.jsonb_build_object(
    'status', 'id_based',
    'project_id', p_project_id,
    'migration_epoch', p_migration_epoch,
    'validation', v_validation
  );
end;
$$;

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
      and operation.entity_kind = 'document'
      and operation.provenance_kind = 'CONTRACT_BATCH'
      and batch.sync_protocol_version = 3
      and batch.canonical_contract_sha256 =
        'fae86b4e6385ee37fbeb99f9256194ec319b64bfda92974ce90a3eb70d2e7a46'
  ) then
    raise exception using errcode = 'P0001', message = 'PROTOCOL_TOO_OLD';
  end if;
  return new;
end;
$$;

drop trigger if exists document_versions_contract_boundary on public.document_versions;
create trigger document_versions_contract_boundary
before insert on public.document_versions
for each row execute function private.enforce_document_write_boundary();

revoke all on function private.rfc8785_canonical_json(jsonb) from public, anon, authenticated;
revoke all on function private.jsonb_rfc8785_sha256(jsonb) from public, anon, authenticated;
revoke all on function private.atomic_failure(uuid, text, text, text, integer) from public, anon, authenticated;
revoke all on function private.storage_name_v1_result(text) from public, anon, authenticated;
revoke all on function private.append_operation_event(uuid, uuid, text, text, uuid, jsonb) from public, anon, authenticated;
revoke all on function private.validate_contract_request(uuid, uuid, text, integer, jsonb, jsonb) from public, anon, authenticated;
revoke all on function private.apply_structure_intent(uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function private.enforce_document_write_boundary() from public, anon, authenticated;

revoke all on function public.atomic_structure_commit(jsonb) from public, anon;
revoke all on function public.cancel_sync_operation(uuid, uuid) from public, anon;
revoke all on function public.validate_project_sync_migration(uuid) from public, anon;
revoke all on function public.begin_project_sync_migration(uuid, uuid, text) from public, anon;
revoke all on function public.complete_project_sync_migration(uuid, uuid, integer) from public, anon;

grant execute on function public.atomic_structure_commit(jsonb) to authenticated;
grant execute on function public.cancel_sync_operation(uuid, uuid) to authenticated;
grant execute on function public.validate_project_sync_migration(uuid) to authenticated;
grant execute on function public.begin_project_sync_migration(uuid, uuid, text) to authenticated;
grant execute on function public.complete_project_sync_migration(uuid, uuid, integer) to authenticated;

comment on function public.atomic_structure_commit(jsonb) is
  'Contract 0.1.0 ordered structure batch: validates all intents and commits all or rolls back all.';
comment on function public.cancel_sync_operation(uuid, uuid) is
  'Appends the deterministic cancel_requested event without mutating operation intent.';
comment on function public.begin_project_sync_migration(uuid, uuid, text) is
  'Explicit owner-only LEGACY to MIGRATING boundary. Never called automatically.';
comment on function public.complete_project_sync_migration(uuid, uuid, integer) is
  'Explicit owner-only MIGRATING to ID_BASED transition after validation.';

commit;
