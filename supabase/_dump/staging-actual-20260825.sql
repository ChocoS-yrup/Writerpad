


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "private";


ALTER SCHEMA "private" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE OR REPLACE FUNCTION "private"."append_operation_event"("p_operation_id" "uuid", "p_event_id" "uuid", "p_event_type" "text", "p_error_code" "text" DEFAULT NULL::"text", "p_blocking_operation_id" "uuid" DEFAULT NULL::"uuid", "p_detail" "jsonb" DEFAULT NULL::"jsonb") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "private"."append_operation_event"("p_operation_id" "uuid", "p_event_id" "uuid", "p_event_type" "text", "p_error_code" "text", "p_blocking_operation_id" "uuid", "p_detail" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."apply_structure_intent"("p_project_id" "uuid", "p_user_id" "uuid", "p_intent" "jsonb") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "private"."apply_structure_intent"("p_project_id" "uuid", "p_user_id" "uuid", "p_intent" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."atomic_failure"("p_batch_id" "uuid", "p_batch_payload_sha256" "text", "p_code" "text", "p_message" "text", "p_failed_sequence" integer DEFAULT NULL::integer) RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "private"."atomic_failure"("p_batch_id" "uuid", "p_batch_payload_sha256" "text", "p_code" "text", "p_message" "text", "p_failed_sequence" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."content_sha256"("p_content" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE STRICT
    SET "search_path" TO ''
    AS $$
  select pg_catalog.encode(
    extensions.digest(pg_catalog.convert_to(p_content, 'UTF8'), 'sha256'),
    'hex'
  );
$$;


ALTER FUNCTION "private"."content_sha256"("p_content" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."default_casefold_unicode15"("p_value" "text") RETURNS "text"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
declare
  v_normalized text;
  v_character text;
  v_mapping text;
  v_result text := '';
begin
  if p_value is null then
    return null;
  end if;

  v_normalized := private.nfkc_unicode15(p_value);
  for v_character in
    select value
    from pg_catalog.regexp_split_to_table(v_normalized, '') as value
  loop
    select mapping into v_mapping
    from private.unicode15_casefold
    where source_codepoint = pg_catalog.ascii(v_character);
    v_result := v_result || coalesce(v_mapping, v_character);
  end loop;

  return private.nfkc_unicode15(v_result);
end;
$$;


ALTER FUNCTION "private"."default_casefold_unicode15"("p_value" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."document_failure"("p_batch_id" "uuid", "p_batch_payload_sha256" "text", "p_code" "text", "p_message" "text", "p_failed_sequence" integer DEFAULT NULL::integer) RETURNS "jsonb"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
  select pg_catalog.jsonb_build_object(
    'kind', 'document_commit_failure',
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


ALTER FUNCTION "private"."document_failure"("p_batch_id" "uuid", "p_batch_payload_sha256" "text", "p_code" "text", "p_message" "text", "p_failed_sequence" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."document_relative_path"("p_project_id" "uuid", "p_parent_folder_id" "uuid", "p_name" "text") RETURNS "text"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
declare
  v_parent_id uuid := p_parent_folder_id;
  v_folder public.folders%rowtype;
  v_parts text[] := array[p_name]::text[];
  v_seen uuid[] := '{}'::uuid[];
  v_depth integer := 0;
  v_path text;
begin
  perform private.storage_name_v1(p_name);
  while v_parent_id is not null loop
    v_depth := v_depth + 1;
    if v_depth > 1024 then
      raise exception using errcode = 'P0001', message = 'PARENT_CYCLE';
    end if;
    select * into v_folder
    from public.folders
    where folder_id = v_parent_id and project_id = p_project_id;
    if not found or v_folder.is_deleted then
      raise exception using errcode = 'P0001', message = 'FOLDER_NOT_FOUND';
    end if;
    if v_folder.folder_id = any(v_seen) then
      raise exception using errcode = 'P0001', message = 'PARENT_CYCLE';
    end if;
    v_seen := pg_catalog.array_append(v_seen, v_folder.folder_id);
    v_parts := pg_catalog.array_prepend(v_folder.name, v_parts);
    v_parent_id := v_folder.parent_folder_id;
  end loop;
  v_path := pg_catalog.array_to_string(v_parts, '/');
  if not private.is_valid_relative_path(v_path) then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;
  return v_path;
end;
$$;


ALTER FUNCTION "private"."document_relative_path"("p_project_id" "uuid", "p_parent_folder_id" "uuid", "p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."enforce_document_write_boundary"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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
        '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670'
  ) then
    raise exception using errcode = 'P0001', message = 'PROTOCOL_TOO_OLD';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "private"."enforce_document_write_boundary"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."has_project_role"("p_project_id" "uuid", "p_user_id" "uuid", "p_minimum_role" "text" DEFAULT 'viewer'::"text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select
    p_user_id is not null
    and p_minimum_role in ('owner', 'editor', 'viewer')
    and exists (
      select 1
      from public.projects p
      left join public.project_members m
        on m.project_id = p.project_id
       and m.user_id = p_user_id
      where p.project_id = p_project_id
        and p.trashed_at is null
        and (
          p.owner_id = p_user_id
          or case p_minimum_role
            when 'owner' then m.role = 'owner'
            when 'editor' then m.role in ('owner', 'editor')
            when 'viewer' then m.role in ('owner', 'editor', 'viewer')
          end
        )
    );
$$;


ALTER FUNCTION "private"."has_project_role"("p_project_id" "uuid", "p_user_id" "uuid", "p_minimum_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."is_valid_entry_name"("p_name" "text") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $_$
  select
    p_name is not null
    and p_name <> ''
    and p_name = pg_catalog.btrim(p_name)
    and pg_catalog.char_length(p_name) <= 255
    and p_name not in ('.', '..')
    and pg_catalog.right(p_name, 1) <> '.'
    and p_name !~ E'[<>:"/\\\\|?*]'
    and p_name !~ '[[:cntrl:]]'
    and pg_catalog.upper(pg_catalog.split_part(p_name, '.', 1)) <> all (
      array[
        'CON', 'PRN', 'AUX', 'NUL', 'CLOCK$',
        'COM1', 'COM2', 'COM3', 'COM4', 'COM5',
        'COM6', 'COM7', 'COM8', 'COM9',
        'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5',
        'LPT6', 'LPT7', 'LPT8', 'LPT9'
      ]::text[]
    );
$_$;


ALTER FUNCTION "private"."is_valid_entry_name"("p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."is_valid_relative_path"("p_path" "text") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $_$
  select
    p_path is not null
    and p_path <> ''
    and p_path = pg_catalog.btrim(p_path)
    and pg_catalog.length(p_path) <= 1024
    and p_path !~ E'(^/|\\\\|//|(^|/)\\.{1,2}(/|$)|/$)';
$_$;


ALTER FUNCTION "private"."is_valid_relative_path"("p_path" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."jsonb_rfc8785_sha256"("p_value" "jsonb") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE STRICT
    SET "search_path" TO ''
    AS $$
  select pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(private.rfc8785_canonical_json(p_value), 'UTF8'),
      'sha256'
    ),
    'hex'
  );
$$;


ALTER FUNCTION "private"."jsonb_rfc8785_sha256"("p_value" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."nfkc_unicode15"("p_value" "text") RETURNS "text"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
declare
  v_character text;
  v_assigned_buffer text := '';
  v_result text := '';
begin
  if p_value is null then return null; end if;
  for v_character in
    select value from pg_catalog.regexp_split_to_table(p_value, '') as value
  loop
    if private.unicode15_is_assigned(pg_catalog.ascii(v_character)) then
      v_assigned_buffer := v_assigned_buffer || v_character;
    else
      if v_assigned_buffer <> '' then
        v_result := v_result || normalize(v_assigned_buffer, NFKC);
        v_assigned_buffer := '';
      end if;
      v_result := v_result || v_character;
    end if;
  end loop;
  if v_assigned_buffer <> '' then
    v_result := v_result || normalize(v_assigned_buffer, NFKC);
  end if;
  return v_result;
end;
$$;


ALTER FUNCTION "private"."nfkc_unicode15"("p_value" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."reject_append_only_mutation"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  raise exception using errcode = 'P0001', message = 'APPEND_ONLY_LEDGER';
end;
$$;


ALTER FUNCTION "private"."reject_append_only_mutation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."rfc8785_canonical_json"("p_value" "jsonb") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE STRICT
    SET "search_path" TO ''
    AS $_$
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
$_$;


ALTER FUNCTION "private"."rfc8785_canonical_json"("p_value" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."storage_name_v1"("p_name" "text") RETURNS "bytea"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
begin
  if pg_catalog.current_setting('writerpad.contract_sha256', true) =
     'abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c' then
    return private.storage_name_v2(p_name);
  end if;
  return private.storage_name_v1_legacy(p_name);
end;
$$;


ALTER FUNCTION "private"."storage_name_v1"("p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."storage_name_v1_legacy"("p_name" "text") RETURNS "bytea"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $_$
declare
  v_character text;
  v_codepoint integer;
  v_normalized text;
  v_basename text;
begin
  if p_name is null then
    raise exception using errcode = 'P0001', message = 'STORAGE_NAME_INVALID';
  end if;

  for v_character in
    select value
    from pg_catalog.regexp_split_to_table(p_name, '') as value
  loop
    v_codepoint := pg_catalog.ascii(v_character);
    if v_character in ('/', E'\\')
       or v_codepoint between 0 and 31
       or v_codepoint = 127 then
      raise exception using errcode = 'P0001', message = 'STORAGE_NAME_INVALID';
    end if;
  end loop;

  v_normalized := private.default_casefold_unicode15(p_name);
  v_normalized := pg_catalog.regexp_replace(v_normalized, '[ .]+$', '');
  if v_normalized in ('', '.', '..') then
    raise exception using errcode = 'P0001', message = 'STORAGE_NAME_INVALID';
  end if;

  v_basename := pg_catalog.split_part(v_normalized, '.', 1);
  if v_basename = any(array[
    'con', 'prn', 'aux', 'nul',
    'com1', 'com2', 'com3', 'com4', 'com5',
    'com6', 'com7', 'com8', 'com9',
    'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5',
    'lpt6', 'lpt7', 'lpt8', 'lpt9'
  ]::text[]) then
    raise exception using errcode = 'P0001', message = 'STORAGE_NAME_RESERVED';
  end if;

  return pg_catalog.convert_to(v_normalized, 'UTF8');
end;
$_$;


ALTER FUNCTION "private"."storage_name_v1_legacy"("p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."storage_name_v1_result"("p_name" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "private"."storage_name_v1_result"("p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."storage_name_v1_text"("p_name" "text") RETURNS "text"
    LANGUAGE "sql" STABLE
    SET "search_path" TO ''
    AS $$
  select pg_catalog.convert_from(private.storage_name_v1(p_name), 'UTF8');
$$;


ALTER FUNCTION "private"."storage_name_v1_text"("p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."storage_name_v2"("p_name" "text") RETURNS "bytea"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $_$
declare
  v_character text;
  v_codepoint integer;
  v_previous_codepoint integer;
  v_mapping text;
  v_normalized text;
  v_folded text := '';
  v_basename text;
begin
  if p_name is null then
    raise exception using errcode = 'P0001', message = 'STORAGE_NAME_INVALID';
  end if;

  -- Normative pre-NFKC order: assigned baseline, exclusions, then the
  -- supplementary-scalar adjacency guard.
  for v_character in
    select value from pg_catalog.regexp_split_to_table(p_name, '') as value
  loop
    v_codepoint := pg_catalog.ascii(v_character);
    if not private.storage_name_v2_is_assigned(v_codepoint) then
      raise exception using errcode = 'P0001', message = 'STORAGE_NAME_UNASSIGNED';
    end if;
  end loop;
  for v_character in
    select value from pg_catalog.regexp_split_to_table(p_name, '') as value
  loop
    v_codepoint := pg_catalog.ascii(v_character);
    if private.storage_name_v2_is_excluded(v_codepoint) then
      raise exception using errcode = 'P0001', message = 'STORAGE_NAME_UNSUPPORTED_SCALAR';
    end if;
  end loop;
  for v_character in
    select value from pg_catalog.regexp_split_to_table(p_name, '') as value
  loop
    v_codepoint := pg_catalog.ascii(v_character);
    if v_previous_codepoint > 65535
       and (
         v_codepoint in (65438, 65439)
         or exists (
           select 1 from private.storage_name_v2_nonzero_ccc
           where codepoint = v_codepoint
         )
       ) then
      raise exception using errcode = 'P0001', message = 'STORAGE_NAME_INVALID';
    end if;
    v_previous_codepoint := v_codepoint;
  end loop;

  v_normalized := normalize(p_name, NFKC);
  for v_character in
    select value from pg_catalog.regexp_split_to_table(v_normalized, '') as value
  loop
    select mapping into v_mapping
    from private.storage_name_v2_casefold
    where source_codepoint = pg_catalog.ascii(v_character);
    v_folded := v_folded || coalesce(v_mapping, v_character);
  end loop;
  v_normalized := normalize(v_folded, NFKC);

  for v_character in
    select value from pg_catalog.regexp_split_to_table(v_normalized, '') as value
  loop
    v_codepoint := pg_catalog.ascii(v_character);
    if v_character in ('/', E'\\')
       or v_codepoint between 0 and 31
       or v_codepoint = 127 then
      raise exception using errcode = 'P0001', message = 'STORAGE_NAME_INVALID';
    end if;
  end loop;

  -- Defensive post-NFKC baseline recheck. This remains mandatory even though
  -- the released frozen assets do not currently make it reachable naturally.
  for v_character in
    select value from pg_catalog.regexp_split_to_table(v_normalized, '') as value
  loop
    if not private.storage_name_v2_is_assigned(pg_catalog.ascii(v_character)) then
      raise exception using errcode = 'P0001', message = 'STORAGE_NAME_UNASSIGNED';
    end if;
  end loop;

  v_normalized := pg_catalog.regexp_replace(v_normalized, '[ .]+$', '');
  if v_normalized in ('', '.', '..') then
    raise exception using errcode = 'P0001', message = 'STORAGE_NAME_INVALID';
  end if;

  v_basename := pg_catalog.split_part(v_normalized, '.', 1);
  if v_basename = any(array[
    'con', 'prn', 'aux', 'nul',
    'com1', 'com2', 'com3', 'com4', 'com5',
    'com6', 'com7', 'com8', 'com9',
    'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5',
    'lpt6', 'lpt7', 'lpt8', 'lpt9'
  ]::text[]) then
    raise exception using errcode = 'P0001', message = 'STORAGE_NAME_RESERVED';
  end if;

  return pg_catalog.convert_to(v_normalized, 'UTF8');
end;
$_$;


ALTER FUNCTION "private"."storage_name_v2"("p_name" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "private"."storage_name_v2"("p_name" "text") IS 'Contract 0.3.0 storage-name-v2 collision key using frozen assignment, exclusion, and casefold tables.';



CREATE OR REPLACE FUNCTION "private"."storage_name_v2_is_assigned"("p_codepoint" integer) RETURNS boolean
    LANGUAGE "sql" STABLE STRICT
    SET "search_path" TO ''
    AS $$
  select exists (
    select 1
    from private.storage_name_v2_assigned_ranges
    where p_codepoint between range_start and range_end
  );
$$;


ALTER FUNCTION "private"."storage_name_v2_is_assigned"("p_codepoint" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."storage_name_v2_is_excluded"("p_codepoint" integer) RETURNS boolean
    LANGUAGE "sql" STABLE STRICT
    SET "search_path" TO ''
    AS $$
  select exists (
    select 1
    from private.storage_name_v2_excluded_ranges
    where p_codepoint between range_start and range_end
  );
$$;


ALTER FUNCTION "private"."storage_name_v2_is_excluded"("p_codepoint" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."storage_name_v2_result"("p_name" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO ''
    AS $$
declare
  v_key bytea;
begin
  v_key := private.storage_name_v2(p_name);
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


ALTER FUNCTION "private"."storage_name_v2_result"("p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."unicode15_is_assigned"("p_codepoint" integer) RETURNS boolean
    LANGUAGE "sql" STABLE STRICT
    SET "search_path" TO ''
    AS $$
  select exists (
    select 1
    from private.unicode15_assigned_ranges
    where p_codepoint between range_start and range_end
  );
$$;


ALTER FUNCTION "private"."unicode15_is_assigned"("p_codepoint" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."validate_contract_request"("p_user_id" "uuid", "p_project_id" "uuid", "p_project_sync_mode" "text", "p_migration_epoch" integer, "p_batch" "jsonb", "p_ordered_intents" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_allowlist private.sync_contract_allowlist%rowtype;
  v_settings public.project_sync_settings%rowtype;
  v_actual_mode text := 'LEGACY';
  v_actual_epoch integer := 0;
  v_capabilities text[];
  v_capability_count integer;
  v_distinct_capability_count integer;
  v_required text[];
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

  select * into v_allowlist
  from private.sync_contract_allowlist
  where canonical_contract_sha256 = p_batch->>'canonical_contract_sha256'
    and contract_version = p_batch->>'contract_version'
    and enabled
    and revoked_at is null
    and valid_from <= pg_catalog.transaction_timestamp();
  if not found then
    if exists (
      select 1 from private.sync_contract_allowlist
      where canonical_contract_sha256 = p_batch->>'canonical_contract_sha256'
        and contract_version = p_batch->>'contract_version'
    ) then
      raise exception using errcode = 'P0001', message = 'CONTRACT_NOT_ALLOWED';
    end if;
    if exists (
      select 1 from private.sync_contract_allowlist
      where contract_version = p_batch->>'contract_version'
    ) then
      raise exception using errcode = 'P0001', message = 'CONTRACT_DIGEST_MISMATCH';
    end if;
    raise exception using errcode = 'P0001', message = 'CONTRACT_NOT_ALLOWED';
  end if;
  if (p_batch->>'sync_protocol_version')::integer <> 3
     or not ((p_batch->>'sync_protocol_version')::integer = any(v_allowlist.allowed_protocol_versions)) then
    raise exception using errcode = 'P0001', message = 'PROTOCOL_TOO_OLD';
  end if;

  if v_allowlist.canonical_contract_sha256 =
     'abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c' then
    v_required := array[
      'folders_authoritative', 'tree_order_ids', 'tombstones',
      'immutable_batch_contract_metadata', 'operation_attempt_history',
      'operation_state_events', 'storage_name_v2', 'document_commit_v1'
    ]::text[];
  else
    v_required := array[
      'folders_authoritative', 'tree_order_ids', 'tombstones',
      'immutable_batch_contract_metadata', 'operation_attempt_history',
      'operation_state_events', 'storage_name_v1', 'document_commit_v1'
    ]::text[];
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
       or v_settings.active_contract_sha256 <> v_allowlist.canonical_contract_sha256 then
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

  perform pg_catalog.set_config(
    'writerpad.contract_sha256', v_allowlist.canonical_contract_sha256, true
  );
end;
$$;


ALTER FUNCTION "private"."validate_contract_request"("p_user_id" "uuid", "p_project_id" "uuid", "p_project_sync_mode" "text", "p_migration_epoch" integer, "p_batch" "jsonb", "p_ordered_intents" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."acquire_edit_lease"("p_document_id" "uuid", "p_device_id" "uuid", "p_ttl_seconds" integer DEFAULT 90) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_user_id uuid := auth.uid();
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_ttl integer;
  v_document public.documents%rowtype;
  v_lease public.edit_leases%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_document_id is null or p_device_id is null then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  v_ttl := greatest(30, least(coalesce(p_ttl_seconds, 90), 120));

  select * into v_document
  from public.documents
  where document_id = p_document_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'DOCUMENT_NOT_FOUND';
  end if;
  if not private.has_project_role(v_document.project_id, v_user_id, 'editor') then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  delete from public.edit_leases
  where document_id = p_document_id and expires_at <= v_now;

  select * into v_lease
  from public.edit_leases
  where document_id = p_document_id
  for update;

  if found then
    if v_lease.holder_user_id <> v_user_id
       or v_lease.holder_device_id <> p_device_id then
      raise exception using
        errcode = 'P0001',
        message = 'LEASE_CONFLICT',
        detail = pg_catalog.jsonb_build_object('expires_at', v_lease.expires_at)::text;
    end if;

    update public.edit_leases
    set renewed_at = v_now,
        expires_at = v_now + pg_catalog.make_interval(secs => v_ttl)
    where document_id = p_document_id
    returning * into v_lease;
  else
    insert into public.edit_leases (
      document_id, holder_user_id, holder_device_id, expires_at
    ) values (
      p_document_id, v_user_id, p_device_id,
      v_now + pg_catalog.make_interval(secs => v_ttl)
    )
    returning * into v_lease;
  end if;

  return pg_catalog.jsonb_build_object(
    'document_id', v_lease.document_id,
    'lease_token', v_lease.lease_token,
    'device_id', v_lease.holder_device_id,
    'expires_at', v_lease.expires_at
  );
end;
$$;


ALTER FUNCTION "public"."acquire_edit_lease"("p_document_id" "uuid", "p_device_id" "uuid", "p_ttl_seconds" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."atomic_structure_commit"("p_request" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_batch_id uuid;
  v_payload_sha text;
  v_error_code text;
begin
  -- Parse only the response identity before checking auth. Do not trust any
  -- authorization metadata from the request; auth.uid() is authoritative.
  begin
    v_batch_id := (p_request->'batch'->>'batch_id')::uuid;
    v_payload_sha := p_request->'batch'->>'batch_payload_sha256';
  exception when others then
    v_batch_id := null;
    v_payload_sha := null;
  end;

  if auth.uid() is null then
    return private.atomic_failure(
      v_batch_id, v_payload_sha, 'AUTH_REQUIRED',
      'authentication is required', null
    );
  end if;

  begin
    return public.atomic_structure_commit_legacy(p_request);
  exception when sqlstate 'P0001' then
    v_error_code := sqlerrm;
    if v_error_code = 'FORBIDDEN' then
      return private.atomic_failure(
        v_batch_id, v_payload_sha, 'FORBIDDEN',
        'the caller is not an editor of this project', null
      );
    end if;
    raise;
  end;
end;
$$;


ALTER FUNCTION "public"."atomic_structure_commit"("p_request" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."atomic_structure_commit"("p_request" "jsonb") IS 'Contract 0.3.0 atomic structure commit with canonical auth failure envelopes.';



CREATE OR REPLACE FUNCTION "public"."atomic_structure_commit_legacy"("p_request" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "public"."atomic_structure_commit_legacy"("p_request" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."atomic_structure_commit_legacy"("p_request" "jsonb") IS 'Contract 0.2.0 ordered structure batch: validates all intents and commits all or rolls back all.';



CREATE OR REPLACE FUNCTION "public"."begin_project_sync_migration"("p_project_id" "uuid", "p_writer_device_id" "uuid", "p_target_contract_sha256" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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
  if not exists (
    select 1 from private.sync_contract_allowlist
    where canonical_contract_sha256 = p_target_contract_sha256
      and 3 = any(allowed_protocol_versions)
      and enabled
      and revoked_at is null
      and valid_from <= pg_catalog.transaction_timestamp()
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


ALTER FUNCTION "public"."begin_project_sync_migration"("p_project_id" "uuid", "p_writer_device_id" "uuid", "p_target_contract_sha256" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."begin_project_sync_migration"("p_project_id" "uuid", "p_writer_device_id" "uuid", "p_target_contract_sha256" "text") IS 'Explicit owner-only LEGACY to MIGRATING boundary. Never called automatically.';



CREATE OR REPLACE FUNCTION "public"."cancel_sync_operation"("p_operation_id" "uuid", "p_cancel_event_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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


ALTER FUNCTION "public"."cancel_sync_operation"("p_operation_id" "uuid", "p_cancel_event_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."cancel_sync_operation"("p_operation_id" "uuid", "p_cancel_event_id" "uuid") IS 'Appends the deterministic cancel_requested event without mutating operation intent.';



CREATE OR REPLACE FUNCTION "public"."commit_document"("p_document_id" "uuid", "p_project_id" "uuid", "p_base_revision" bigint, "p_operation_id" "uuid", "p_device_id" "uuid", "p_relative_path" "text", "p_content" "text", "p_is_deleted" boolean DEFAULT false, "p_lease_token" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_user_id uuid := auth.uid();
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_hash text;
  v_document public.documents%rowtype;
  v_version public.document_versions%rowtype;
  v_lease public.edit_leases%rowtype;
  v_revision bigint;
  v_kind text;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_document_id is null
     or p_project_id is null
     or p_operation_id is null
     or p_device_id is null
     or p_base_revision is null
     or p_base_revision < 0
     or p_is_deleted is null
     or p_relative_path is null
     or p_content is null
     or not private.is_valid_relative_path(p_relative_path)
     or pg_catalog.octet_length(p_content) > 10485760 then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;
  if not private.has_project_role(p_project_id, v_user_id, 'editor') then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  v_hash := private.content_sha256(p_content);

  -- A fixed lock order makes operation replay, document creation and path checks deterministic.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('operation:' || p_operation_id::text, 0)
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('document:' || p_document_id::text, 0)
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('project:' || p_project_id::text, 0)
  );

  select dv.* into v_version
  from public.document_versions dv
  where dv.operation_id = p_operation_id;

  if found then
    if v_version.document_id <> p_document_id
       or v_version.project_id <> p_project_id
       or v_version.base_revision <> p_base_revision
       or v_version.device_id <> p_device_id
       or v_version.relative_path <> p_relative_path
       or v_version.content_hash <> v_hash
       or v_version.is_deleted <> p_is_deleted
       or v_version.created_by <> v_user_id then
      raise exception using errcode = 'P0001', message = 'OPERATION_ID_REUSED';
    end if;

    return pg_catalog.jsonb_build_object(
      'status', 'replayed',
      'document_id', v_version.document_id,
      'version_id', v_version.version_id,
      'operation_id', v_version.operation_id,
      'operation_kind', v_version.operation_kind,
      'revision', v_version.revision,
      'relative_path', v_version.relative_path,
      'is_deleted', v_version.is_deleted,
      'content_hash', v_version.content_hash,
      'committed_at', v_version.created_at
    );
  end if;

  select * into v_document
  from public.documents
  where document_id = p_document_id
  for update;

  if p_base_revision = 0 then
    if found then
      raise exception using errcode = 'P0001', message = 'DOCUMENT_ALREADY_EXISTS';
    end if;
    if p_is_deleted or p_lease_token is not null then
      raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
    end if;
    if exists (
      select 1 from public.documents
      where project_id = p_project_id
        and relative_path = p_relative_path
        and not is_deleted
    ) then
      raise exception using errcode = 'P0001', message = 'PATH_CONFLICT';
    end if;

    v_revision := 1;
    v_kind := 'create';
    insert into public.documents (
      document_id, project_id, relative_path, content, revision,
      is_deleted, deleted_at, created_by, updated_by, created_at, updated_at
    ) values (
      p_document_id, p_project_id, p_relative_path, p_content, v_revision,
      false, null, v_user_id, v_user_id, v_now, v_now
    );
  else
    if not found or v_document.project_id <> p_project_id then
      raise exception using errcode = 'P0001', message = 'DOCUMENT_NOT_FOUND';
    end if;
    if v_document.revision <> p_base_revision then
      raise exception using
        errcode = 'P0001',
        message = 'REVISION_CONFLICT',
        detail = pg_catalog.jsonb_build_object(
          'current_revision', v_document.revision,
          'current_hash', private.content_sha256(v_document.content),
          'is_deleted', v_document.is_deleted
        )::text;
    end if;
    if p_lease_token is null then
      raise exception using errcode = 'P0001', message = 'LEASE_REQUIRED';
    end if;

    select * into v_lease
    from public.edit_leases
    where document_id = p_document_id
    for update;

    if not found
       or v_lease.holder_user_id <> v_user_id
       or v_lease.holder_device_id <> p_device_id
       or v_lease.lease_token <> p_lease_token
       or v_lease.expires_at <= v_now then
      delete from public.edit_leases
      where document_id = p_document_id and expires_at <= v_now;
      raise exception using errcode = 'P0001', message = 'LEASE_EXPIRED';
    end if;

    if not p_is_deleted and exists (
      select 1 from public.documents
      where project_id = p_project_id
        and relative_path = p_relative_path
        and document_id <> p_document_id
        and not is_deleted
    ) then
      raise exception using errcode = 'P0001', message = 'PATH_CONFLICT';
    end if;

    v_revision := v_document.revision + 1;
    v_kind := case
      when not v_document.is_deleted and p_is_deleted then 'delete'
      when v_document.is_deleted and not p_is_deleted then 'restore'
      when v_document.relative_path <> p_relative_path
       and v_document.content = p_content then 'move'
      else 'update'
    end;
  end if;

  insert into public.document_versions (
    document_id, project_id, revision, base_revision, operation_id, device_id,
    operation_kind, relative_path, content, content_hash, is_deleted,
    created_by, created_at
  ) values (
    p_document_id, p_project_id, v_revision, p_base_revision, p_operation_id, p_device_id,
    v_kind, p_relative_path, p_content, v_hash, p_is_deleted,
    v_user_id, v_now
  )
  returning * into v_version;

  update public.documents
  set relative_path = p_relative_path,
      content = p_content,
      revision = v_revision,
      current_version_id = v_version.version_id,
      is_deleted = p_is_deleted,
      deleted_at = case when p_is_deleted then v_now else null end,
      updated_by = v_user_id,
      updated_at = v_now
  where document_id = p_document_id;

  if p_is_deleted then
    delete from public.edit_leases where document_id = p_document_id;
  elsif p_base_revision > 0 then
    update public.edit_leases
    set renewed_at = v_now,
        expires_at = v_now + pg_catalog.make_interval(secs => 90)
    where document_id = p_document_id;
  end if;

  return pg_catalog.jsonb_build_object(
    'status', 'committed',
    'document_id', v_version.document_id,
    'version_id', v_version.version_id,
    'operation_id', v_version.operation_id,
    'operation_kind', v_version.operation_kind,
    'revision', v_version.revision,
    'relative_path', v_version.relative_path,
    'is_deleted', v_version.is_deleted,
    'content_hash', v_version.content_hash,
    'committed_at', v_version.created_at
  );
end;
$$;


ALTER FUNCTION "public"."commit_document"("p_document_id" "uuid", "p_project_id" "uuid", "p_base_revision" bigint, "p_operation_id" "uuid", "p_device_id" "uuid", "p_relative_path" "text", "p_content" "text", "p_is_deleted" boolean, "p_lease_token" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."commit_document"("p_document_id" "uuid", "p_project_id" "uuid", "p_base_revision" bigint, "p_operation_id" "uuid", "p_device_id" "uuid", "p_relative_path" "text", "p_content" "text", "p_is_deleted" boolean, "p_lease_token" "uuid") IS 'Atomic, optimistic and idempotent document commit RPC for sync protocol v2.';



CREATE OR REPLACE FUNCTION "public"."commit_folder"("p_folder_id" "uuid", "p_project_id" "uuid", "p_base_revision" bigint, "p_operation_id" "uuid", "p_device_id" "uuid", "p_parent_folder_id" "uuid", "p_name" "text", "p_is_deleted" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_user_id uuid := auth.uid();
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_project public.projects%rowtype;
  v_folder public.folders%rowtype;
  v_parent public.folders%rowtype;
  v_version public.folder_versions%rowtype;
  v_revision bigint;
  v_kind text;
  v_cycle boolean := false;
  v_folder_exists boolean := false;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_folder_id is null
     or p_project_id is null
     or p_operation_id is null
     or p_device_id is null
     or p_base_revision is null
     or p_base_revision < 0
     or p_is_deleted is null
     or not private.is_valid_entry_name(p_name) then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;
  if p_parent_folder_id = p_folder_id then
    raise exception using errcode = 'P0001', message = 'FOLDER_CYCLE';
  end if;

  -- One project lock serializes sibling-name and ancestry checks. The operation
  -- and folder locks make a retry with the same UUID deterministic.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('operation:' || p_operation_id::text, 0)
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('folder:' || p_folder_id::text, 0)
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('project:' || p_project_id::text, 0)
  );

  select * into v_project
  from public.projects
  where project_id = p_project_id
  for update;

  if not found then
    if exists (
      select 1
      from private.project_purge_tombstones tombstone
      where tombstone.project_id = p_project_id
        and tombstone.owner_id = v_user_id
    ) then
      raise exception using errcode = 'P0001', message = 'PROJECT_PURGED';
    end if;
    raise exception using errcode = 'P0001', message = 'PROJECT_NOT_FOUND';
  end if;
  if v_project.trashed_at is not null then
    raise exception using errcode = 'P0001', message = 'PROJECT_TRASHED';
  end if;
  if not private.has_project_role(p_project_id, v_user_id, 'editor') then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  select * into v_version
  from public.folder_versions
  where operation_id = p_operation_id;

  if found then
    if v_version.folder_id <> p_folder_id
       or v_version.project_id <> p_project_id
       or v_version.base_revision <> p_base_revision
       or v_version.device_id <> p_device_id
       or v_version.parent_folder_id is distinct from p_parent_folder_id
       or v_version.name <> p_name
       or v_version.is_deleted <> p_is_deleted
       or v_version.created_by <> v_user_id then
      raise exception using errcode = 'P0001', message = 'OPERATION_ID_REUSED';
    end if;

    return pg_catalog.jsonb_build_object(
      'status', 'replayed',
      'folder_id', v_version.folder_id,
      'version_id', v_version.version_id,
      'operation_id', v_version.operation_id,
      'operation_kind', v_version.operation_kind,
      'revision', v_version.revision,
      'parent_folder_id', v_version.parent_folder_id,
      'name', v_version.name,
      'is_deleted', v_version.is_deleted,
      'committed_at', v_version.created_at
    );
  end if;

  select * into v_folder
  from public.folders
  where folder_id = p_folder_id
  for update;
  v_folder_exists := found;

  if p_parent_folder_id is not null then
    select * into v_parent
    from public.folders
    where folder_id = p_parent_folder_id
      and project_id = p_project_id
    for update;

    if not found or v_parent.is_deleted then
      raise exception using errcode = 'P0001', message = 'PARENT_FOLDER_NOT_FOUND';
    end if;

    with recursive ancestors as (
      select folder.folder_id, folder.parent_folder_id
      from public.folders folder
      where folder.folder_id = p_parent_folder_id
        and folder.project_id = p_project_id
      union all
      select parent.folder_id, parent.parent_folder_id
      from public.folders parent
      join ancestors child on parent.folder_id = child.parent_folder_id
      where parent.project_id = p_project_id
    )
    select exists (
      select 1 from ancestors where folder_id = p_folder_id
    ) into v_cycle;

    if v_cycle then
      raise exception using errcode = 'P0001', message = 'FOLDER_CYCLE';
    end if;
  end if;

  if p_base_revision = 0 then
    if v_folder_exists then
      raise exception using errcode = 'P0001', message = 'FOLDER_ALREADY_EXISTS';
    end if;
    if p_is_deleted then
      raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
    end if;
    if exists (
      select 1
      from public.folders sibling
      where sibling.project_id = p_project_id
        and sibling.parent_folder_id is not distinct from p_parent_folder_id
        and pg_catalog.lower(sibling.name) = pg_catalog.lower(p_name)
        and not sibling.is_deleted
    ) then
      raise exception using errcode = 'P0001', message = 'FOLDER_NAME_CONFLICT';
    end if;

    v_revision := 1;
    v_kind := 'create';
    insert into public.folders (
      folder_id, project_id, parent_folder_id, name, revision,
      is_deleted, deleted_at, created_by, updated_by, created_at, updated_at
    ) values (
      p_folder_id, p_project_id, p_parent_folder_id, p_name, v_revision,
      false, null, v_user_id, v_user_id, v_now, v_now
    );
  else
    if not v_folder_exists or v_folder.project_id <> p_project_id then
      raise exception using errcode = 'P0001', message = 'FOLDER_NOT_FOUND';
    end if;
    if v_folder.revision <> p_base_revision then
      raise exception using
        errcode = 'P0001',
        message = 'REVISION_CONFLICT',
        detail = pg_catalog.jsonb_build_object(
          'current_revision', v_folder.revision,
          'parent_folder_id', v_folder.parent_folder_id,
          'name', v_folder.name,
          'is_deleted', v_folder.is_deleted
        )::text;
    end if;
    if p_is_deleted and exists (
      select 1
      from public.folders child
      where child.project_id = p_project_id
        and child.parent_folder_id = p_folder_id
        and not child.is_deleted
    ) then
      raise exception using errcode = 'P0001', message = 'FOLDER_NOT_EMPTY';
    end if;
    if not p_is_deleted and exists (
      select 1
      from public.folders sibling
      where sibling.project_id = p_project_id
        and sibling.parent_folder_id is not distinct from p_parent_folder_id
        and sibling.folder_id <> p_folder_id
        and pg_catalog.lower(sibling.name) = pg_catalog.lower(p_name)
        and not sibling.is_deleted
    ) then
      raise exception using errcode = 'P0001', message = 'FOLDER_NAME_CONFLICT';
    end if;

    v_revision := v_folder.revision + 1;
    v_kind := case
      when not v_folder.is_deleted and p_is_deleted then 'delete'
      when v_folder.is_deleted and not p_is_deleted then 'restore'
      when v_folder.parent_folder_id is distinct from p_parent_folder_id then 'move'
      when v_folder.name <> p_name then 'rename'
      else 'update'
    end;
  end if;

  insert into public.folder_versions (
    folder_id, project_id, revision, base_revision, operation_id, device_id,
    operation_kind, parent_folder_id, name, is_deleted, created_by, created_at
  ) values (
    p_folder_id, p_project_id, v_revision, p_base_revision, p_operation_id,
    p_device_id, v_kind, p_parent_folder_id, p_name, p_is_deleted,
    v_user_id, v_now
  )
  returning * into v_version;

  update public.folders
  set parent_folder_id = p_parent_folder_id,
      name = p_name,
      revision = v_revision,
      current_version_id = v_version.version_id,
      is_deleted = p_is_deleted,
      deleted_at = case when p_is_deleted then v_now else null end,
      updated_by = v_user_id,
      updated_at = v_now
  where folder_id = p_folder_id;

  return pg_catalog.jsonb_build_object(
    'status', 'committed',
    'folder_id', v_version.folder_id,
    'version_id', v_version.version_id,
    'operation_id', v_version.operation_id,
    'operation_kind', v_version.operation_kind,
    'revision', v_version.revision,
    'parent_folder_id', v_version.parent_folder_id,
    'name', v_version.name,
    'is_deleted', v_version.is_deleted,
    'committed_at', v_version.created_at
  );
end;
$$;


ALTER FUNCTION "public"."commit_folder"("p_folder_id" "uuid", "p_project_id" "uuid", "p_base_revision" bigint, "p_operation_id" "uuid", "p_device_id" "uuid", "p_parent_folder_id" "uuid", "p_name" "text", "p_is_deleted" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."complete_project_sync_migration"("p_project_id" "uuid", "p_writer_device_id" "uuid", "p_migration_epoch" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

  update public.documents
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


ALTER FUNCTION "public"."complete_project_sync_migration"("p_project_id" "uuid", "p_writer_device_id" "uuid", "p_migration_epoch" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."complete_project_sync_migration"("p_project_id" "uuid", "p_writer_device_id" "uuid", "p_migration_epoch" integer) IS 'Explicit owner-only MIGRATING to ID_BASED transition after validation.';



CREATE OR REPLACE FUNCTION "public"."document_commit"("p_request" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_batch_id uuid;
  v_payload_sha text;
  v_error_code text;
begin
  -- Parse only the response identity before checking auth. Do not trust any
  -- authorization metadata from the request; auth.uid() is authoritative.
  begin
    v_batch_id := (p_request->'batch'->>'batch_id')::uuid;
    v_payload_sha := p_request->'batch'->>'batch_payload_sha256';
  exception when others then
    v_batch_id := null;
    v_payload_sha := null;
  end;

  if auth.uid() is null then
    return private.document_failure(
      v_batch_id, v_payload_sha, 'AUTH_REQUIRED',
      'authentication is required', null
    );
  end if;

  begin
    return public.document_commit_legacy(p_request);
  exception when sqlstate 'P0001' then
    v_error_code := sqlerrm;
    if v_error_code = 'FORBIDDEN' then
      return private.document_failure(
        v_batch_id, v_payload_sha, 'FORBIDDEN',
        'the caller is not an editor of this project', null
      );
    end if;
    raise;
  end;
end;
$$;


ALTER FUNCTION "public"."document_commit"("p_request" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."document_commit"("p_request" "jsonb") IS 'Contract 0.3.0 document commit with canonical auth failure envelopes.';



CREATE OR REPLACE FUNCTION "public"."document_commit_legacy"("p_request" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_user_id uuid := auth.uid();
  v_project_id uuid;
  v_mode text;
  v_epoch integer;
  v_batch jsonb;
  v_intents jsonb;
  v_intent jsonb;
  v_payload jsonb;
  v_batch_id uuid;
  v_operation_id uuid;
  v_document_id uuid;
  v_device_id uuid;
  v_base_revision bigint;
  v_intent_kind text;
  v_payload_sha text;
  v_request_sha text;
  v_content text;
  v_content_sha text;
  v_content_bytes integer;
  v_name text;
  v_parent_id uuid;
  v_structure_revision bigint;
  v_storage_key bytea;
  v_relative_path text;
  v_is_deleted boolean;
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_started_at timestamptz := pg_catalog.clock_timestamp();
  v_document public.documents%rowtype;
  v_version public.document_versions%rowtype;
  v_existing_batch public.sync_batches%rowtype;
  v_existing_result public.sync_batch_results%rowtype;
  v_result_revision bigint;
  v_response jsonb;
  v_error_code text;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if pg_catalog.jsonb_typeof(p_request) <> 'object'
     or p_request->>'kind' <> 'document_commit_request'
     or exists (
       select 1 from pg_catalog.jsonb_object_keys(p_request) key
       where key not in (
         'kind', 'project_id', 'project_sync_mode', 'migration_epoch',
         'batch', 'ordered_intents'
       )
     ) then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  begin
    v_project_id := (p_request->>'project_id')::uuid;
    v_mode := p_request->>'project_sync_mode';
    v_epoch := (p_request->>'migration_epoch')::integer;
    v_batch := p_request->'batch';
    v_intents := p_request->'ordered_intents';
    if pg_catalog.jsonb_typeof(v_intents) <> 'array'
       or pg_catalog.jsonb_array_length(v_intents) <> 1 then
      raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
    end if;
    v_intent := v_intents->0;
    v_payload := v_intent->'payload';
    v_batch_id := (v_batch->>'batch_id')::uuid;
    v_operation_id := (v_intent->>'operation_id')::uuid;
    v_document_id := (v_intent->>'document_id')::uuid;
    v_device_id := (v_batch->>'writer_device_id')::uuid;
    v_base_revision := (v_intent->>'base_revision')::bigint;
    v_intent_kind := v_intent->>'intent_kind';
    v_payload_sha := v_batch->>'batch_payload_sha256';
    v_request_sha := private.jsonb_rfc8785_sha256(p_request);
    v_content := v_payload->>'content';
    v_content_sha := v_payload->>'content_sha256';
    v_content_bytes := (v_payload->>'content_byte_count')::integer;
    v_name := v_payload->>'name';
    v_parent_id := case when v_payload->'parent_folder_id' = 'null'::jsonb
      then null else (v_payload->>'parent_folder_id')::uuid end;
    v_structure_revision := (v_payload->>'structure_revision')::bigint;
    v_is_deleted := (v_payload->>'is_deleted')::boolean;
  exception when others then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('project:' || v_project_id::text, 0)
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('document:' || v_document_id::text, 0)
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
       or v_existing_batch.writer_device_id <> v_device_id
       or v_existing_batch.client_build_id <> v_batch->>'client_build_id'
       or v_existing_batch.sync_protocol_version <> (v_batch->>'sync_protocol_version')::integer
       or v_existing_batch.contract_version <> v_batch->>'contract_version'
       or v_existing_batch.canonical_contract_sha256 <> v_batch->>'canonical_contract_sha256'
       or v_existing_batch.batch_payload_sha256 <> v_payload_sha
       or v_existing_batch.project_sync_mode <> v_mode
       or v_existing_batch.migration_epoch <> v_epoch
       or v_existing_batch.request_sha256 <> v_request_sha then
      return private.document_failure(
        v_batch_id, v_payload_sha, 'BATCH_ID_REUSED',
        'batch_id already belongs to a different payload', null
      );
    end if;
    select * into strict v_existing_result
    from public.sync_batch_results
    where batch_id = v_batch_id;
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
    if v_intent->>'entity_kind' <> 'document'
       or (v_intent->>'sequence')::integer <> 1
       or (v_intent->>'batch_id')::uuid <> v_batch_id
       or v_intent_kind not in ('create', 'update', 'delete', 'restore')
       or pg_catalog.jsonb_typeof(v_payload) <> 'object'
       or pg_catalog.char_length(v_name) < 1
       or pg_catalog.char_length(v_name) > 255
       or v_structure_revision < 1
       or v_content_bytes < 0
       or v_content_bytes > 10485760 then
      raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
    end if;
    if v_intent->>'payload_sha256' <> private.jsonb_rfc8785_sha256(v_payload) then
      raise exception using errcode = 'P0001', message = 'CONTRACT_DIGEST_MISMATCH';
    end if;
    if pg_catalog.octet_length(v_content) <> v_content_bytes then
      raise exception using errcode = 'P0001', message = 'CONTENT_SIZE_MISMATCH';
    end if;
    if private.content_sha256(v_content) <> v_content_sha then
      raise exception using errcode = 'P0001', message = 'CONTENT_DIGEST_MISMATCH';
    end if;
    if (v_intent_kind = 'create' and (v_base_revision <> 0 or v_is_deleted))
       or (v_intent_kind <> 'create' and v_base_revision < 1)
       or (v_intent_kind = 'update' and v_is_deleted)
       or (v_intent_kind = 'delete' and not v_is_deleted)
       or (v_intent_kind = 'restore' and v_is_deleted) then
      raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
    end if;
    v_storage_key := private.storage_name_v1(v_name);
    v_relative_path := private.document_relative_path(
      v_project_id, v_parent_id, v_name
    );
  exception when sqlstate 'P0001' then
    return private.document_failure(v_batch_id, v_payload_sha, sqlerrm, sqlerrm, 1);
  end;

  if exists (
    select 1 from public.sync_operations where operation_id = v_operation_id
  ) then
    return private.document_failure(
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
    v_batch_id, v_project_id, v_user_id, v_device_id,
    v_batch->>'client_build_id', (v_batch->>'sync_protocol_version')::integer,
    v_batch->>'contract_version', v_batch->>'canonical_contract_sha256',
    array(select value from pg_catalog.jsonb_array_elements_text(v_batch->'client_capabilities') order by value),
    v_payload_sha, v_mode, v_epoch, v_request_sha
  );
  insert into public.sync_operations (
    operation_id, project_id, provenance_kind, batch_id, sequence,
    entity_kind, entity_id, intent_kind, base_revision, payload_sha256,
    payload, supersedes_operation_id, created_by
  ) values (
    v_operation_id, v_project_id, 'CONTRACT_BATCH', v_batch_id, 1,
    'document', v_document_id, v_intent_kind, v_base_revision,
    v_intent->>'payload_sha256', v_payload,
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
  if v_intent ? 'supersedes_operation_id' then
    perform private.append_operation_event(
      (v_intent->>'supersedes_operation_id')::uuid,
      pg_catalog.gen_random_uuid(), 'superseded', null, v_operation_id,
      pg_catalog.jsonb_build_object('successor_operation_id', v_operation_id)
    );
  end if;

  begin
    select * into v_document
    from public.documents
    where document_id = v_document_id
    for update;

    if v_intent_kind = 'create' then
      if found then
        raise exception using errcode = 'P0001', message = 'DOCUMENT_ALREADY_EXISTS';
      end if;
      if exists (
        select 1 from public.folders sibling
        where sibling.project_id = v_project_id
          and sibling.parent_folder_id is not distinct from v_parent_id
          and not sibling.is_deleted
          and sibling.storage_name_key = v_storage_key
      ) or exists (
        select 1 from public.documents sibling
        where sibling.project_id = v_project_id
          and sibling.parent_folder_id is not distinct from v_parent_id
          and not sibling.is_deleted
          and sibling.storage_name_key = v_storage_key
      ) then
        raise exception using errcode = 'P0001', message = 'PATH_CONFLICT';
      end if;
      v_result_revision := 1;
      insert into public.documents (
        document_id, project_id, relative_path, content, revision,
        current_version_id, is_deleted, deleted_at, created_by, updated_by,
        created_at, updated_at, parent_folder_id, storage_name_key, name,
        structure_revision
      ) values (
        v_document_id, v_project_id, v_relative_path, v_content, 1,
        null, false, null, v_user_id, v_user_id, v_now, v_now,
        v_parent_id, v_storage_key, v_name, 1
      );
    else
      if not found or v_document.project_id <> v_project_id then
        raise exception using errcode = 'P0001', message = 'DOCUMENT_NOT_FOUND';
      end if;
      if v_document.revision <> v_base_revision then
        raise exception using errcode = 'P0001', message = 'REVISION_CONFLICT';
      end if;
      if v_document.name is distinct from v_name
         or v_document.parent_folder_id is distinct from v_parent_id
         or v_document.structure_revision is distinct from v_structure_revision then
        raise exception using errcode = 'P0001', message = 'STRUCTURE_REVISION_CONFLICT';
      end if;
      if v_intent_kind = 'update' and v_document.is_deleted then
        raise exception using errcode = 'P0001', message = 'DOCUMENT_NOT_FOUND';
      end if;
      if v_intent_kind = 'delete' then
        if v_document.is_deleted then
          raise exception using errcode = 'P0001', message = 'DOCUMENT_NOT_FOUND';
        end if;
        if exists (
          select 1 from public.tree_orders tree
          where tree.project_id = v_project_id
            and v_document_id = any(tree.children)
        ) then
          raise exception using errcode = 'P0001', message = 'INVARIANT_VIOLATION';
        end if;
      end if;
      if v_intent_kind = 'restore' and not v_document.is_deleted then
        raise exception using errcode = 'P0001', message = 'DOCUMENT_ALREADY_EXISTS';
      end if;
      if v_intent_kind in ('delete', 'restore')
         and (v_document.content <> v_content
           or private.content_sha256(v_document.content) <> v_content_sha) then
        raise exception using errcode = 'P0001', message = 'CONTENT_DIGEST_MISMATCH';
      end if;
      v_result_revision := v_document.revision + 1;
    end if;

    insert into public.document_versions (
      document_id, project_id, revision, base_revision, operation_id, device_id,
      operation_kind, relative_path, content, content_hash, is_deleted,
      created_by, created_at
    ) values (
      v_document_id, v_project_id, v_result_revision, v_base_revision,
      v_operation_id, v_device_id, v_intent_kind, v_relative_path, v_content,
      v_content_sha, v_is_deleted, v_user_id, v_now
    ) returning * into v_version;

    update public.documents
    set content = v_content,
        revision = v_result_revision,
        current_version_id = v_version.version_id,
        is_deleted = v_is_deleted,
        deleted_at = case when v_is_deleted then v_now else null end,
        updated_by = v_user_id,
        updated_at = v_now
    where document_id = v_document_id;
    if v_is_deleted then
      delete from public.edit_leases where document_id = v_document_id;
    end if;
  exception when sqlstate 'P0001' then
    v_error_code := sqlerrm;
  end;

  if v_error_code is not null then
    v_response := private.document_failure(
      v_batch_id, v_payload_sha, v_error_code, v_error_code, 1
    );
    perform private.append_operation_event(
      v_operation_id, pg_catalog.gen_random_uuid(),
      case when v_error_code in ('REVISION_CONFLICT', 'STRUCTURE_REVISION_CONFLICT')
        then 'conflict_detected' else 'blocked' end,
      v_error_code, null, pg_catalog.jsonb_build_object('failed_sequence', 1)
    );
    insert into public.sync_operation_attempts (
      attempt_id, operation_id, attempt_number, started_at, finished_at,
      rpc_name, outcome, request_sha256, response_sha256, error_code, error_detail
    ) values (
      pg_catalog.gen_random_uuid(), v_operation_id, 1, v_started_at,
      pg_catalog.clock_timestamp(), 'document_commit',
      case when v_error_code in ('REVISION_CONFLICT', 'STRUCTURE_REVISION_CONFLICT')
        then 'conflict' else 'blocked' end,
      v_request_sha, private.jsonb_rfc8785_sha256(v_response), v_error_code,
      pg_catalog.jsonb_build_object('failed_sequence', 1)
    );
    insert into public.sync_batch_results (
      batch_id, response, response_sha256, applied
    ) values (
      v_batch_id, v_response, private.jsonb_rfc8785_sha256(v_response), false
    );
    return v_response;
  end if;

  v_response := pg_catalog.jsonb_build_object(
    'kind', 'document_commit_success',
    'batch_id', v_batch_id,
    'batch_payload_sha256', v_payload_sha,
    'status', 'committed',
    'applied', true,
    'results', pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'sequence', 1,
      'operation_id', v_operation_id,
      'document_id', v_document_id,
      'result_revision', v_result_revision,
      'structure_revision', v_structure_revision,
      'parent_folder_id', v_parent_id,
      'name', v_name,
      'content_sha256', v_content_sha,
      'content_byte_count', v_content_bytes,
      'is_deleted', v_is_deleted
    ))
  );
  perform private.append_operation_event(
    v_operation_id, pg_catalog.gen_random_uuid(), 'committed'
  );
  insert into public.sync_operation_attempts (
    attempt_id, operation_id, attempt_number, started_at, finished_at,
    rpc_name, outcome, request_sha256, response_sha256, result_revision
  ) values (
    pg_catalog.gen_random_uuid(), v_operation_id, 1, v_started_at,
    pg_catalog.clock_timestamp(), 'document_commit', 'committed',
    v_request_sha, private.jsonb_rfc8785_sha256(v_response), v_result_revision
  );
  insert into public.sync_batch_results (
    batch_id, response, response_sha256, applied
  ) values (
    v_batch_id, v_response, private.jsonb_rfc8785_sha256(v_response), true
  );
  return v_response;
end;
$$;


ALTER FUNCTION "public"."document_commit_legacy"("p_request" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."document_commit_legacy"("p_request" "jsonb") IS 'Contract 0.2.0 single-document create/update/delete/restore boundary with deterministic replay.';



CREATE OR REPLACE FUNCTION "public"."ensure_project"("p_project_id" "uuid", "p_name" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_user_id uuid := auth.uid();
  v_owner_id uuid;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_project_id is null or p_name is null or pg_catalog.btrim(p_name) = '' then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('project:' || p_project_id::text, 0)
  );
  select owner_id into v_owner_id
  from public.projects
  where project_id = p_project_id;

  if not found then
    insert into public.projects (project_id, owner_id, name)
    values (p_project_id, v_user_id, pg_catalog.btrim(p_name));
    insert into public.project_members (project_id, user_id, role)
    values (p_project_id, v_user_id, 'owner')
    on conflict (project_id, user_id) do update set role = 'owner';
  elsif v_owner_id = v_user_id then
    insert into public.project_members (project_id, user_id, role)
    values (p_project_id, v_user_id, 'owner')
    on conflict (project_id, user_id) do update set role = 'owner';
    update public.projects
    set name = pg_catalog.btrim(p_name),
        updated_at = pg_catalog.transaction_timestamp()
    where project_id = p_project_id;
  elsif not private.has_project_role(p_project_id, v_user_id, 'editor') then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  else
    update public.projects
    set name = pg_catalog.btrim(p_name),
        updated_at = pg_catalog.transaction_timestamp()
    where project_id = p_project_id;
  end if;

  return pg_catalog.jsonb_build_object(
    'project_id', p_project_id,
    'name', pg_catalog.btrim(p_name)
  );
end;
$$;


ALTER FUNCTION "public"."ensure_project"("p_project_id" "uuid", "p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_edit_lease"("p_document_id" "uuid", "p_device_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_user_id uuid := auth.uid();
  v_project_id uuid;
  v_lease public.edit_leases%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_document_id is null or p_device_id is null then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  select project_id into v_project_id
  from public.documents
  where document_id = p_document_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'DOCUMENT_NOT_FOUND';
  end if;
  if not private.has_project_role(v_project_id, v_user_id, 'viewer') then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  select * into v_lease
  from public.edit_leases
  where document_id = p_document_id
    and expires_at > pg_catalog.transaction_timestamp();

  if not found then
    return pg_catalog.jsonb_build_object(
      'document_id', p_document_id,
      'state', 'available'
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'document_id', p_document_id,
    'state', case
      when v_lease.holder_user_id = v_user_id
       and v_lease.holder_device_id = p_device_id then 'held_by_me'
      else 'held_by_other'
    end,
    'expires_at', v_lease.expires_at
  );
end;
$$;


ALTER FUNCTION "public"."get_edit_lease"("p_document_id" "uuid", "p_device_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_project_status"("p_project_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_user_id uuid := auth.uid();
  v_project public.projects%rowtype;
  v_is_member boolean := false;
  v_purged_owner uuid;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_project_id is null then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  select * into v_project
  from public.projects
  where project_id = p_project_id;

  if found then
    select exists (
      select 1
      from public.project_members member
      where member.project_id = p_project_id
        and member.user_id = v_user_id
    ) into v_is_member;

    if v_project.owner_id <> v_user_id and not v_is_member then
      raise exception using errcode = 'P0001', message = 'FORBIDDEN';
    end if;

    return pg_catalog.jsonb_build_object(
      'project_id', v_project.project_id,
      'state', case
        when v_project.trashed_at is null then 'active'
        else 'trashed'
      end,
      'name', v_project.name,
      'updated_at', v_project.updated_at,
      'trashed_at', v_project.trashed_at
    );
  end if;

  select owner_id into v_purged_owner
  from private.project_purge_tombstones
  where project_id = p_project_id;

  if found and v_purged_owner = v_user_id then
    return pg_catalog.jsonb_build_object(
      'project_id', p_project_id,
      'state', 'purged'
    );
  end if;

  raise exception using errcode = 'P0001', message = 'PROJECT_NOT_FOUND';
end;
$$;


ALTER FUNCTION "public"."get_project_status"("p_project_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sync_handshake"("p_project_id" "uuid", "p_contract_sha256" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_user_id uuid := auth.uid();
  v_mode text := 'LEGACY';
  v_epoch integer := 0;
  v_active_contract_sha256 text;
  v_contract private.sync_contract_allowlist%rowtype;
  v_server_protocol_version integer;
  v_supported boolean := false;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_project_id is null
     or p_contract_sha256 is null
     or p_contract_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;
  if not private.has_project_role(p_project_id, v_user_id, 'viewer') then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  -- Row absence is the server contract's authoritative LEGACY/epoch-0 state.
  select
    settings.project_sync_mode,
    settings.migration_epoch,
    settings.active_contract_sha256
  into v_mode, v_epoch, v_active_contract_sha256
  from public.project_sync_settings as settings
  where settings.project_id = p_project_id;

  if not found then
    v_mode := 'LEGACY';
    v_epoch := 0;
    v_active_contract_sha256 := null;
  end if;

  select * into v_contract
  from private.sync_contract_allowlist as allowlist
  where allowlist.canonical_contract_sha256 = p_contract_sha256
    and allowlist.enabled
    and allowlist.revoked_at is null
    and allowlist.valid_from <= pg_catalog.transaction_timestamp();

  if found then
    select max(protocol_version)
    into v_server_protocol_version
    from pg_catalog.unnest(
      v_contract.allowed_protocol_versions
    ) as protocol(protocol_version);

    v_supported := v_mode = 'LEGACY'
      or v_active_contract_sha256 = p_contract_sha256;
  end if;

  return pg_catalog.jsonb_build_object(
    'supported', v_supported,
    'project_id', p_project_id,
    'project_sync_mode', v_mode,
    'migration_epoch', v_epoch,
    'contract_version', case when v_supported
      then v_contract.contract_version else null end,
    'canonical_contract_sha256', case when v_supported
      then v_contract.canonical_contract_sha256 else null end,
    'server_contract_sha256', case when v_supported
      then v_contract.canonical_contract_sha256 else null end,
    'supported_protocol_versions', case when v_supported
      then pg_catalog.to_jsonb(v_contract.allowed_protocol_versions)
      else '[]'::jsonb end,
    'server_protocol_version', case when v_supported
      then v_server_protocol_version else null end,
    'server_capabilities', case when v_supported
      then pg_catalog.to_jsonb(v_contract.server_capabilities)
      else '[]'::jsonb end
  );
end;
$_$;


ALTER FUNCTION "public"."get_sync_handshake"("p_project_id" "uuid", "p_contract_sha256" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_sync_handshake"("p_project_id" "uuid", "p_contract_sha256" "text") IS 'Authenticated, read-only advertisement of project mode/epoch and one exact enabled sync-contract digest.';



CREATE OR REPLACE FUNCTION "public"."list_trashed_projects"() RETURNS TABLE("project_id" "uuid", "name" "text", "trashed_at" timestamp with time zone, "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  return query
  select p.project_id, p.name, p.trashed_at, p.updated_at
  from public.projects p
  where p.owner_id = v_user_id
    and p.trashed_at is not null
  order by p.trashed_at desc, p.name, p.project_id;
end;
$$;


ALTER FUNCTION "public"."list_trashed_projects"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."purge_project"("p_project_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_user_id uuid := auth.uid();
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_project public.projects%rowtype;
  v_tombstone_owner uuid;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_project_id is null then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('project:' || p_project_id::text, 0)
  );

  select * into v_project
  from public.projects
  where project_id = p_project_id
  for update;

  if not found then
    select owner_id into v_tombstone_owner
    from private.project_purge_tombstones
    where project_id = p_project_id;

    if found and v_tombstone_owner = v_user_id then
      return pg_catalog.jsonb_build_object(
        'status', 'purged',
        'project_id', p_project_id,
        'already_purged', true
      );
    end if;
    raise exception using errcode = 'P0001', message = 'PROJECT_NOT_FOUND';
  end if;
  if v_project.owner_id <> v_user_id then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;
  if v_project.trashed_at is null then
    raise exception using errcode = 'P0001', message = 'PROJECT_NOT_TRASHED';
  end if;

  insert into private.project_purge_tombstones (
    project_id, owner_id, purged_by, purged_at
  ) values (
    p_project_id, v_project.owner_id, v_user_id, v_now
  )
  on conflict (project_id) do nothing;

  delete from public.projects where project_id = p_project_id;

  return pg_catalog.jsonb_build_object(
    'status', 'purged',
    'project_id', p_project_id,
    'already_purged', false,
    'purged_at', v_now
  );
end;
$$;


ALTER FUNCTION "public"."purge_project"("p_project_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."release_edit_lease"("p_document_id" "uuid", "p_device_id" "uuid", "p_lease_token" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_document_id is null or p_device_id is null or p_lease_token is null then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  delete from public.edit_leases
  where document_id = p_document_id
    and holder_user_id = v_user_id
    and holder_device_id = p_device_id
    and lease_token = p_lease_token;

  return found;
end;
$$;


ALTER FUNCTION "public"."release_edit_lease"("p_document_id" "uuid", "p_device_id" "uuid", "p_lease_token" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."renew_edit_lease"("p_document_id" "uuid", "p_device_id" "uuid", "p_lease_token" "uuid", "p_ttl_seconds" integer DEFAULT 90) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_user_id uuid := auth.uid();
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_ttl integer;
  v_project_id uuid;
  v_lease public.edit_leases%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_document_id is null or p_device_id is null or p_lease_token is null then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  select project_id into v_project_id
  from public.documents
  where document_id = p_document_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'DOCUMENT_NOT_FOUND';
  end if;
  if not private.has_project_role(v_project_id, v_user_id, 'editor') then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  select * into v_lease
  from public.edit_leases
  where document_id = p_document_id
  for update;

  if not found
     or v_lease.holder_user_id <> v_user_id
     or v_lease.holder_device_id <> p_device_id
     or v_lease.lease_token <> p_lease_token
     or v_lease.expires_at <= v_now then
    delete from public.edit_leases
    where document_id = p_document_id and expires_at <= v_now;
    raise exception using errcode = 'P0001', message = 'LEASE_EXPIRED';
  end if;

  v_ttl := greatest(30, least(coalesce(p_ttl_seconds, 90), 120));
  update public.edit_leases
  set renewed_at = v_now,
      expires_at = v_now + pg_catalog.make_interval(secs => v_ttl)
  where document_id = p_document_id
  returning * into v_lease;

  return pg_catalog.jsonb_build_object(
    'document_id', v_lease.document_id,
    'lease_token', v_lease.lease_token,
    'device_id', v_lease.holder_device_id,
    'expires_at', v_lease.expires_at
  );
end;
$$;


ALTER FUNCTION "public"."renew_edit_lease"("p_document_id" "uuid", "p_device_id" "uuid", "p_lease_token" "uuid", "p_ttl_seconds" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."restore_project"("p_project_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_user_id uuid := auth.uid();
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_project public.projects%rowtype;
  v_was_trashed boolean;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_project_id is null then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('project:' || p_project_id::text, 0)
  );

  select * into v_project
  from public.projects
  where project_id = p_project_id
  for update;

  if not found then
    if exists (
      select 1 from private.project_purge_tombstones
      where project_id = p_project_id
    ) then
      raise exception using errcode = 'P0001', message = 'PROJECT_PURGED';
    end if;
    raise exception using errcode = 'P0001', message = 'PROJECT_NOT_FOUND';
  end if;
  if v_project.owner_id <> v_user_id then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  v_was_trashed := v_project.trashed_at is not null;
  if v_was_trashed then
    update public.projects
    set trashed_at = null,
        trashed_by = null,
        updated_at = v_now
    where project_id = p_project_id
    returning * into v_project;
  end if;

  return pg_catalog.jsonb_build_object(
    'status', 'active',
    'project_id', v_project.project_id,
    'name', v_project.name,
    'restored', v_was_trashed
  );
end;
$$;


ALTER FUNCTION "public"."restore_project"("p_project_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."touch_editor_locks_locked_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
NEW.locked_at = timezone('utc'::text, now());
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."touch_editor_locks_locked_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."touch_writing_contents_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
NEW.updated_at = timezone('utc'::text, now());
RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."touch_writing_contents_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trash_project"("p_project_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_user_id uuid := auth.uid();
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_project public.projects%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_project_id is null then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('project:' || p_project_id::text, 0)
  );

  select * into v_project
  from public.projects
  where project_id = p_project_id
  for update;

  if not found then
    if exists (
      select 1 from private.project_purge_tombstones
      where project_id = p_project_id
    ) then
      raise exception using errcode = 'P0001', message = 'PROJECT_PURGED';
    end if;
    raise exception using errcode = 'P0001', message = 'PROJECT_NOT_FOUND';
  end if;
  if v_project.owner_id <> v_user_id then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  if v_project.trashed_at is null then
    update public.projects
    set trashed_at = v_now,
        trashed_by = v_user_id,
        updated_at = v_now
    where project_id = p_project_id
    returning * into v_project;

    delete from public.edit_leases lease
    using public.documents document
    where document.project_id = p_project_id
      and lease.document_id = document.document_id;
  end if;

  return pg_catalog.jsonb_build_object(
    'status', 'trashed',
    'project_id', v_project.project_id,
    'name', v_project.name,
    'trashed_at', v_project.trashed_at
  );
end;
$$;


ALTER FUNCTION "public"."trash_project"("p_project_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_project_sync_migration"("p_project_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_user_id uuid := auth.uid();
  v_contract_sha256 text;
  v_issues jsonb := '[]'::jsonb;
  v_count bigint;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if not private.has_project_role(p_project_id, v_user_id, 'editor') then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  select active_contract_sha256 into v_contract_sha256
  from public.project_sync_settings
  where project_id = p_project_id;
  if v_contract_sha256 is null
     or not exists (
       select 1 from private.sync_contract_allowlist
       where canonical_contract_sha256 = v_contract_sha256
         and enabled and revoked_at is null
     ) then
    raise exception using errcode = 'P0001', message = 'CONTRACT_NOT_ALLOWED';
  end if;
  perform pg_catalog.set_config(
    'writerpad.contract_sha256', v_contract_sha256, true
  );

  select count(*) into v_count
  from (
    select name from public.folders
    where project_id = p_project_id and not is_deleted
    union all
    select name from public.documents
    where project_id = p_project_id and not is_deleted
  ) entry
  where name is null
     or not (private.storage_name_v1_result(name)->>'valid')::boolean;
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
    union all
    select parent_folder_id, private.storage_name_v1(name) as collision_key
    from public.documents
    where project_id = p_project_id
      and not is_deleted
      and name is not null
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


ALTER FUNCTION "public"."validate_project_sync_migration"("p_project_id" "uuid") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "private"."project_purge_tombstones" (
    "project_id" "uuid" NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "purged_by" "uuid" NOT NULL,
    "purged_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL
);


ALTER TABLE "private"."project_purge_tombstones" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "private"."storage_name_v2_assigned_ranges" (
    "range_start" integer NOT NULL,
    "range_end" integer NOT NULL,
    CONSTRAINT "storage_name_v2_assigned_ranges_check" CHECK ((("range_end" >= "range_start") AND ("range_end" <= 1114111))),
    CONSTRAINT "storage_name_v2_assigned_ranges_range_start_check" CHECK ((("range_start" >= 0) AND ("range_start" <= 1114111)))
);


ALTER TABLE "private"."storage_name_v2_assigned_ranges" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "private"."storage_name_v2_casefold" (
    "source_codepoint" integer NOT NULL,
    "mapping" "text" NOT NULL,
    CONSTRAINT "storage_name_v2_casefold_source_codepoint_check" CHECK ((("source_codepoint" >= 0) AND ("source_codepoint" <= 1114111)))
);


ALTER TABLE "private"."storage_name_v2_casefold" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "private"."storage_name_v2_excluded_ranges" (
    "range_start" integer NOT NULL,
    "range_end" integer NOT NULL,
    CONSTRAINT "storage_name_v2_excluded_ranges_check" CHECK ((("range_end" >= "range_start") AND ("range_end" <= 1114111))),
    CONSTRAINT "storage_name_v2_excluded_ranges_range_start_check" CHECK ((("range_start" >= 0) AND ("range_start" <= 1114111)))
);


ALTER TABLE "private"."storage_name_v2_excluded_ranges" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "private"."storage_name_v2_nonzero_ccc" (
    "codepoint" integer NOT NULL,
    CONSTRAINT "storage_name_v2_nonzero_ccc_codepoint_check" CHECK ((("codepoint" >= 0) AND ("codepoint" <= 1114111)))
);


ALTER TABLE "private"."storage_name_v2_nonzero_ccc" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "private"."sync_contract_allowlist" (
    "canonical_contract_sha256" "text" NOT NULL,
    "contract_version" "text" NOT NULL,
    "contract_git_commit" "text" NOT NULL,
    "contract_content_commit" "text" NOT NULL,
    "canonical_contract_bytes" integer NOT NULL,
    "allowed_protocol_versions" integer[] NOT NULL,
    "allowed_client_capabilities" "text"[] NOT NULL,
    "server_capabilities" "text"[] NOT NULL,
    "minimum_client_builds" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "valid_from" timestamp with time zone NOT NULL,
    "revoked_at" timestamp with time zone,
    "enabled" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    CONSTRAINT "sync_contract_allowlist_allowed_client_capabilities_check" CHECK (("array_length"("allowed_client_capabilities", 1) > 0)),
    CONSTRAINT "sync_contract_allowlist_allowed_protocol_versions_check" CHECK (("array_length"("allowed_protocol_versions", 1) > 0)),
    CONSTRAINT "sync_contract_allowlist_canonical_contract_bytes_check" CHECK (("canonical_contract_bytes" > 0)),
    CONSTRAINT "sync_contract_allowlist_canonical_contract_sha256_check" CHECK (("canonical_contract_sha256" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "sync_contract_allowlist_check" CHECK ((("revoked_at" IS NULL) OR ("revoked_at" >= "valid_from"))),
    CONSTRAINT "sync_contract_allowlist_contract_content_commit_check" CHECK (("contract_content_commit" ~ '^[0-9a-f]{40}$'::"text")),
    CONSTRAINT "sync_contract_allowlist_contract_git_commit_check" CHECK (("contract_git_commit" ~ '^[0-9a-f]{40}$'::"text")),
    CONSTRAINT "sync_contract_allowlist_contract_version_check" CHECK (("contract_version" ~ '^[0-9]+\.[0-9]+\.[0-9]+$'::"text")),
    CONSTRAINT "sync_contract_allowlist_server_capabilities_check" CHECK (("array_length"("server_capabilities", 1) > 0))
);


ALTER TABLE "private"."sync_contract_allowlist" OWNER TO "postgres";


COMMENT ON TABLE "private"."sync_contract_allowlist" IS 'Server authority for released sync contracts. 0.2.0 is installed disabled and requires a separate rollout decision.';



CREATE TABLE IF NOT EXISTS "private"."unicode15_assigned_ranges" (
    "range_start" integer NOT NULL,
    "range_end" integer NOT NULL,
    CONSTRAINT "unicode15_assigned_ranges_check" CHECK ((("range_end" >= "range_start") AND ("range_end" <= 1114111))),
    CONSTRAINT "unicode15_assigned_ranges_range_start_check" CHECK ((("range_start" >= 0) AND ("range_start" <= 1114111)))
);


ALTER TABLE "private"."unicode15_assigned_ranges" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "private"."unicode15_casefold" (
    "source_codepoint" integer NOT NULL,
    "mapping" "text" NOT NULL,
    CONSTRAINT "unicode15_casefold_mapping_check" CHECK (("mapping" <> ''::"text")),
    CONSTRAINT "unicode15_casefold_source_codepoint_check" CHECK ((("source_codepoint" >= 0) AND ("source_codepoint" <= 1114111)))
);


ALTER TABLE "private"."unicode15_casefold" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."document_versions" (
    "version_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "document_id" "uuid" NOT NULL,
    "project_id" "uuid" NOT NULL,
    "revision" bigint NOT NULL,
    "base_revision" bigint NOT NULL,
    "operation_id" "uuid" NOT NULL,
    "device_id" "uuid" NOT NULL,
    "operation_kind" "text" NOT NULL,
    "relative_path" "text" NOT NULL,
    "content" "text" NOT NULL,
    "content_hash" "text" NOT NULL,
    "is_deleted" boolean NOT NULL,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    CONSTRAINT "document_versions_base_revision_check" CHECK (("base_revision" >= 0)),
    CONSTRAINT "document_versions_content_check" CHECK (("octet_length"("content") <= 10485760)),
    CONSTRAINT "document_versions_content_hash_check" CHECK (("content_hash" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "document_versions_operation_kind_check" CHECK (("operation_kind" = ANY (ARRAY['create'::"text", 'update'::"text", 'move'::"text", 'delete'::"text", 'restore'::"text"]))),
    CONSTRAINT "document_versions_relative_path_check" CHECK ("private"."is_valid_relative_path"("relative_path")),
    CONSTRAINT "document_versions_revision_check" CHECK (("revision" >= 1))
);

ALTER TABLE ONLY "public"."document_versions" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."document_versions" OWNER TO "postgres";


COMMENT ON TABLE "public"."document_versions" IS 'Supabase sync v2 immutable full-snapshot commit ledger.';



CREATE TABLE IF NOT EXISTS "public"."documents" (
    "document_id" "uuid" NOT NULL,
    "project_id" "uuid" NOT NULL,
    "relative_path" "text" NOT NULL,
    "content" "text" NOT NULL,
    "revision" bigint NOT NULL,
    "current_version_id" "uuid",
    "is_deleted" boolean DEFAULT false NOT NULL,
    "deleted_at" timestamp with time zone,
    "created_by" "uuid" NOT NULL,
    "updated_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    "parent_folder_id" "uuid",
    "storage_name_key" "bytea",
    "name" "text",
    "structure_revision" bigint,
    CONSTRAINT "documents_content_check" CHECK (("octet_length"("content") <= 10485760)),
    CONSTRAINT "documents_deleted_at_ck" CHECK ((("is_deleted" AND ("deleted_at" IS NOT NULL)) OR ((NOT "is_deleted") AND ("deleted_at" IS NULL)))),
    CONSTRAINT "documents_relative_path_check" CHECK ("private"."is_valid_relative_path"("relative_path")),
    CONSTRAINT "documents_revision_check" CHECK (("revision" >= 1))
);

ALTER TABLE ONLY "public"."documents" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."documents" OWNER TO "postgres";


COMMENT ON TABLE "public"."documents" IS 'Supabase sync v2 current document projection. All writes go through commit_document.';



CREATE TABLE IF NOT EXISTS "public"."edit_leases" (
    "document_id" "uuid" NOT NULL,
    "lease_token" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "holder_user_id" "uuid" NOT NULL,
    "holder_device_id" "uuid" NOT NULL,
    "acquired_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    "renewed_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    CONSTRAINT "edit_leases_check" CHECK (("expires_at" > "renewed_at"))
);

ALTER TABLE ONLY "public"."edit_leases" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."edit_leases" OWNER TO "postgres";


COMMENT ON TABLE "public"."edit_leases" IS 'Short-lived edit leases. Tokens are never directly selectable by app roles.';



CREATE TABLE IF NOT EXISTS "public"."folder_versions" (
    "version_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "folder_id" "uuid" NOT NULL,
    "project_id" "uuid" NOT NULL,
    "revision" bigint NOT NULL,
    "base_revision" bigint NOT NULL,
    "operation_id" "uuid" NOT NULL,
    "device_id" "uuid" NOT NULL,
    "operation_kind" "text" NOT NULL,
    "parent_folder_id" "uuid",
    "name" "text" NOT NULL,
    "is_deleted" boolean NOT NULL,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    CONSTRAINT "folder_versions_base_revision_check" CHECK (("base_revision" >= 0)),
    CONSTRAINT "folder_versions_name_check" CHECK ("private"."is_valid_entry_name"("name")),
    CONSTRAINT "folder_versions_operation_kind_check" CHECK (("operation_kind" = ANY (ARRAY['create'::"text", 'rename'::"text", 'move'::"text", 'update'::"text", 'delete'::"text", 'restore'::"text"]))),
    CONSTRAINT "folder_versions_revision_check" CHECK (("revision" >= 1))
);

ALTER TABLE ONLY "public"."folder_versions" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."folder_versions" OWNER TO "postgres";


COMMENT ON TABLE "public"."folder_versions" IS 'Immutable folder history and operation-id idempotency log.';



CREATE TABLE IF NOT EXISTS "public"."folders" (
    "folder_id" "uuid" NOT NULL,
    "project_id" "uuid" NOT NULL,
    "parent_folder_id" "uuid",
    "name" "text" NOT NULL,
    "revision" bigint NOT NULL,
    "current_version_id" "uuid",
    "is_deleted" boolean DEFAULT false NOT NULL,
    "deleted_at" timestamp with time zone,
    "created_by" "uuid" NOT NULL,
    "updated_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    "storage_name_key" "bytea",
    CONSTRAINT "folders_deleted_at_ck" CHECK ((("is_deleted" AND ("deleted_at" IS NOT NULL)) OR ((NOT "is_deleted") AND ("deleted_at" IS NULL)))),
    CONSTRAINT "folders_not_own_parent_ck" CHECK (("parent_folder_id" IS DISTINCT FROM "folder_id")),
    CONSTRAINT "folders_revision_check" CHECK (("revision" >= 1))
);

ALTER TABLE ONLY "public"."folders" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."folders" OWNER TO "postgres";


COMMENT ON TABLE "public"."folders" IS 'Stable cross-device folder projection. Writes only through commit_folder.';



CREATE TABLE IF NOT EXISTS "public"."project_members" (
    "project_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    CONSTRAINT "project_members_role_check" CHECK (("role" = ANY (ARRAY['owner'::"text", 'editor'::"text", 'viewer'::"text"])))
);

ALTER TABLE ONLY "public"."project_members" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."project_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."project_sync_migrations" (
    "migration_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "project_id" "uuid" NOT NULL,
    "migration_epoch" integer NOT NULL,
    "source_mode" "text" NOT NULL,
    "target_mode" "text" NOT NULL,
    "started_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    "started_by_user_id" "uuid" NOT NULL,
    "started_by_device_id" "uuid" NOT NULL,
    "source_contract_sha256" "text",
    "target_contract_sha256" "text" NOT NULL,
    "validation_result" "jsonb",
    "completed_at" timestamp with time zone,
    "completed_by_user_id" "uuid",
    CONSTRAINT "project_sync_migrations_check" CHECK ((("completed_at" IS NULL) OR ("completed_at" >= "started_at"))),
    CONSTRAINT "project_sync_migrations_migration_epoch_check" CHECK (("migration_epoch" > 0)),
    CONSTRAINT "project_sync_migrations_source_contract_sha256_check" CHECK ((("source_contract_sha256" IS NULL) OR ("source_contract_sha256" ~ '^[0-9a-f]{64}$'::"text"))),
    CONSTRAINT "project_sync_migrations_source_mode_check" CHECK (("source_mode" = ANY (ARRAY['LEGACY'::"text", 'MIGRATING'::"text"]))),
    CONSTRAINT "project_sync_migrations_target_mode_check" CHECK (("target_mode" = ANY (ARRAY['MIGRATING'::"text", 'ID_BASED'::"text"])))
);

ALTER TABLE ONLY "public"."project_sync_migrations" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."project_sync_migrations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."project_sync_settings" (
    "project_id" "uuid" NOT NULL,
    "project_sync_mode" "text" DEFAULT 'LEGACY'::"text" NOT NULL,
    "migration_epoch" integer DEFAULT 0 NOT NULL,
    "contract_enforcement_started_at" timestamp with time zone,
    "active_contract_sha256" "text",
    "updated_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    CONSTRAINT "project_sync_settings_check" CHECK (((("project_sync_mode" = 'LEGACY'::"text") AND ("migration_epoch" = 0) AND ("contract_enforcement_started_at" IS NULL) AND ("active_contract_sha256" IS NULL)) OR (("project_sync_mode" = ANY (ARRAY['MIGRATING'::"text", 'ID_BASED'::"text"])) AND ("migration_epoch" > 0) AND ("contract_enforcement_started_at" IS NOT NULL) AND ("active_contract_sha256" IS NOT NULL)))),
    CONSTRAINT "project_sync_settings_migration_epoch_check" CHECK (("migration_epoch" >= 0)),
    CONSTRAINT "project_sync_settings_project_sync_mode_check" CHECK (("project_sync_mode" = ANY (ARRAY['LEGACY'::"text", 'MIGRATING'::"text", 'ID_BASED'::"text"])))
);

ALTER TABLE ONLY "public"."project_sync_settings" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."project_sync_settings" OWNER TO "postgres";


COMMENT ON TABLE "public"."project_sync_settings" IS 'Rows are created only by explicit migration. Row absence means honest LEGACY epoch 0.';



CREATE TABLE IF NOT EXISTS "public"."projects" (
    "project_id" "uuid" NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    "trashed_at" timestamp with time zone,
    "trashed_by" "uuid",
    CONSTRAINT "projects_name_check" CHECK (("btrim"("name") <> ''::"text")),
    CONSTRAINT "projects_trash_state_ck" CHECK (((("trashed_at" IS NULL) AND ("trashed_by" IS NULL)) OR (("trashed_at" IS NOT NULL) AND ("trashed_by" IS NOT NULL))))
);

ALTER TABLE ONLY "public"."projects" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."projects" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sync_batch_results" (
    "batch_id" "uuid" NOT NULL,
    "response" "jsonb" NOT NULL,
    "response_sha256" "text" NOT NULL,
    "applied" boolean NOT NULL,
    "recorded_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    CONSTRAINT "sync_batch_results_response_sha256_check" CHECK (("response_sha256" ~ '^[0-9a-f]{64}$'::"text"))
);

ALTER TABLE ONLY "public"."sync_batch_results" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."sync_batch_results" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sync_batches" (
    "batch_id" "uuid" NOT NULL,
    "project_id" "uuid" NOT NULL,
    "writer_user_id" "uuid" NOT NULL,
    "writer_device_id" "uuid" NOT NULL,
    "client_build_id" "text" NOT NULL,
    "sync_protocol_version" integer NOT NULL,
    "contract_version" "text" NOT NULL,
    "canonical_contract_sha256" "text" NOT NULL,
    "client_capabilities" "text"[] NOT NULL,
    "batch_payload_sha256" "text" NOT NULL,
    "project_sync_mode" "text" NOT NULL,
    "migration_epoch" integer NOT NULL,
    "request_sha256" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    CONSTRAINT "sync_batches_batch_payload_sha256_check" CHECK (("batch_payload_sha256" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "sync_batches_client_build_id_check" CHECK (("client_build_id" <> ''::"text")),
    CONSTRAINT "sync_batches_migration_epoch_check" CHECK (("migration_epoch" >= 0)),
    CONSTRAINT "sync_batches_project_sync_mode_check" CHECK (("project_sync_mode" = ANY (ARRAY['LEGACY'::"text", 'MIGRATING'::"text", 'ID_BASED'::"text"]))),
    CONSTRAINT "sync_batches_request_sha256_check" CHECK (("request_sha256" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "sync_batches_sync_protocol_version_check" CHECK (("sync_protocol_version" > 0))
);

ALTER TABLE ONLY "public"."sync_batches" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."sync_batches" OWNER TO "postgres";


COMMENT ON TABLE "public"."sync_batches" IS 'Immutable CONTRACT_BATCH metadata pinned to WriterPad sync-contract 0.2.0.';



CREATE TABLE IF NOT EXISTS "public"."sync_operation_attempts" (
    "attempt_id" "uuid" NOT NULL,
    "operation_id" "uuid" NOT NULL,
    "attempt_number" integer NOT NULL,
    "started_at" timestamp with time zone NOT NULL,
    "finished_at" timestamp with time zone NOT NULL,
    "rpc_name" "text" NOT NULL,
    "outcome" "text" NOT NULL,
    "request_sha256" "text",
    "response_sha256" "text",
    "http_status" integer,
    "error_code" "text",
    "error_detail" "jsonb",
    "result_revision" bigint,
    CONSTRAINT "sync_operation_attempts_attempt_number_check" CHECK (("attempt_number" > 0)),
    CONSTRAINT "sync_operation_attempts_check" CHECK (("finished_at" >= "started_at")),
    CONSTRAINT "sync_operation_attempts_outcome_check" CHECK (("outcome" = ANY (ARRAY['committed'::"text", 'replayed'::"text", 'retryable_error'::"text", 'conflict'::"text", 'blocked'::"text", 'transport_unknown'::"text"]))),
    CONSTRAINT "sync_operation_attempts_request_sha256_check" CHECK (("request_sha256" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "sync_operation_attempts_response_sha256_check" CHECK (("response_sha256" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "sync_operation_attempts_result_revision_check" CHECK ((("result_revision" IS NULL) OR ("result_revision" > 0))),
    CONSTRAINT "sync_operation_attempts_rpc_name_check" CHECK (("rpc_name" <> ''::"text"))
);

ALTER TABLE ONLY "public"."sync_operation_attempts" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."sync_operation_attempts" OWNER TO "postgres";


COMMENT ON TABLE "public"."sync_operation_attempts" IS 'Append-only operation attempt outcomes.';



CREATE TABLE IF NOT EXISTS "public"."sync_operation_events" (
    "event_id" "uuid" NOT NULL,
    "operation_id" "uuid" NOT NULL,
    "event_sequence" integer NOT NULL,
    "event_type" "text" NOT NULL,
    "error_code" "text",
    "blocking_operation_id" "uuid",
    "detail" "jsonb",
    "recorded_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    CONSTRAINT "sync_operation_events_check" CHECK ((("event_type" <> ALL (ARRAY['blocked'::"text", 'conflict_detected'::"text"])) OR ("error_code" IS NOT NULL) OR ("blocking_operation_id" IS NOT NULL))),
    CONSTRAINT "sync_operation_events_event_sequence_check" CHECK (("event_sequence" > 0)),
    CONSTRAINT "sync_operation_events_event_type_check" CHECK (("event_type" = ANY (ARRAY['enqueued'::"text", 'dispatch_started'::"text", 'retry_scheduled'::"text", 'blocked'::"text", 'conflict_detected'::"text", 'committed'::"text", 'replayed'::"text", 'cancel_requested'::"text", 'superseded'::"text"])))
);

ALTER TABLE ONLY "public"."sync_operation_events" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."sync_operation_events" OWNER TO "postgres";


COMMENT ON TABLE "public"."sync_operation_events" IS 'Append-only state events; current operation state is a rebuildable projection.';



CREATE TABLE IF NOT EXISTS "public"."sync_operations" (
    "operation_id" "uuid" NOT NULL,
    "project_id" "uuid" NOT NULL,
    "provenance_kind" "text" NOT NULL,
    "batch_id" "uuid",
    "sequence" integer,
    "entity_kind" "text" NOT NULL,
    "entity_id" "uuid" NOT NULL,
    "intent_kind" "text" NOT NULL,
    "base_revision" bigint NOT NULL,
    "payload_sha256" "text" NOT NULL,
    "payload" "jsonb" NOT NULL,
    "supersedes_operation_id" "uuid",
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    CONSTRAINT "sync_operations_base_revision_check" CHECK (("base_revision" >= 0)),
    CONSTRAINT "sync_operations_check" CHECK (((("provenance_kind" = 'LEGACY_EPOCH_0'::"text") AND ("batch_id" IS NULL) AND ("sequence" IS NULL)) OR (("provenance_kind" = 'CONTRACT_BATCH'::"text") AND ("batch_id" IS NOT NULL) AND ("sequence" > 0)))),
    CONSTRAINT "sync_operations_check1" CHECK ((("supersedes_operation_id" IS NULL) OR ("supersedes_operation_id" <> "operation_id"))),
    CONSTRAINT "sync_operations_entity_kind_check" CHECK (("entity_kind" = ANY (ARRAY['project'::"text", 'folder'::"text", 'document'::"text", 'tree_order'::"text", 'trash_purge'::"text"]))),
    CONSTRAINT "sync_operations_intent_kind_check" CHECK (("intent_kind" = ANY (ARRAY['ensure'::"text", 'create'::"text", 'update'::"text", 'rename'::"text", 'move'::"text", 'delete'::"text", 'restore'::"text", 'reorder'::"text", 'migrate'::"text"]))),
    CONSTRAINT "sync_operations_payload_sha256_check" CHECK (("payload_sha256" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "sync_operations_provenance_kind_check" CHECK (("provenance_kind" = ANY (ARRAY['LEGACY_EPOCH_0'::"text", 'CONTRACT_BATCH'::"text"])))
);

ALTER TABLE ONLY "public"."sync_operations" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."sync_operations" OWNER TO "postgres";


COMMENT ON TABLE "public"."sync_operations" IS 'Immutable operation intents. Rebase creates a new row linked by supersedes_operation_id.';



CREATE OR REPLACE VIEW "public"."sync_operation_states" WITH ("security_invoker"='true') AS
 SELECT "operation"."operation_id",
    "operation"."project_id",
    "operation"."batch_id",
    "operation"."entity_kind",
    "operation"."entity_id",
    "operation"."intent_kind",
    "latest"."event_sequence",
    "latest"."event_type",
        CASE "latest"."event_type"
            WHEN 'enqueued'::"text" THEN 'pending'::"text"
            WHEN 'dispatch_started'::"text" THEN 'inflight'::"text"
            WHEN 'retry_scheduled'::"text" THEN 'retry_wait'::"text"
            WHEN 'blocked'::"text" THEN 'blocked'::"text"
            WHEN 'conflict_detected'::"text" THEN 'conflict'::"text"
            WHEN 'committed'::"text" THEN 'completed'::"text"
            WHEN 'replayed'::"text" THEN 'completed'::"text"
            WHEN 'cancel_requested'::"text" THEN 'cancelled'::"text"
            WHEN 'superseded'::"text" THEN 'cancelled'::"text"
            ELSE 'pending'::"text"
        END AS "state",
    "latest"."error_code",
    "latest"."recorded_at"
   FROM ("public"."sync_operations" "operation"
     LEFT JOIN LATERAL ( SELECT "event"."event_sequence",
            "event"."event_type",
            "event"."error_code",
            "event"."recorded_at"
           FROM "public"."sync_operation_events" "event"
          WHERE ("event"."operation_id" = "operation"."operation_id")
          ORDER BY "event"."event_sequence" DESC
         LIMIT 1) "latest" ON (true));


ALTER VIEW "public"."sync_operation_states" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tree_orders" (
    "tree_order_id" "uuid" NOT NULL,
    "project_id" "uuid" NOT NULL,
    "parent_folder_id" "uuid",
    "children" "uuid"[] DEFAULT '{}'::"uuid"[] NOT NULL,
    "revision" bigint NOT NULL,
    "created_by" "uuid" NOT NULL,
    "updated_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "transaction_timestamp"() NOT NULL,
    CONSTRAINT "tree_orders_revision_check" CHECK (("revision" >= 1))
);

ALTER TABLE ONLY "public"."tree_orders" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."tree_orders" OWNER TO "postgres";


ALTER TABLE ONLY "private"."project_purge_tombstones"
    ADD CONSTRAINT "project_purge_tombstones_pkey" PRIMARY KEY ("project_id");



ALTER TABLE ONLY "private"."storage_name_v2_assigned_ranges"
    ADD CONSTRAINT "storage_name_v2_assigned_ranges_pkey" PRIMARY KEY ("range_start");



ALTER TABLE ONLY "private"."storage_name_v2_casefold"
    ADD CONSTRAINT "storage_name_v2_casefold_pkey" PRIMARY KEY ("source_codepoint");



ALTER TABLE ONLY "private"."storage_name_v2_excluded_ranges"
    ADD CONSTRAINT "storage_name_v2_excluded_ranges_pkey" PRIMARY KEY ("range_start");



ALTER TABLE ONLY "private"."storage_name_v2_nonzero_ccc"
    ADD CONSTRAINT "storage_name_v2_nonzero_ccc_pkey" PRIMARY KEY ("codepoint");



ALTER TABLE ONLY "private"."sync_contract_allowlist"
    ADD CONSTRAINT "sync_contract_allowlist_pkey" PRIMARY KEY ("canonical_contract_sha256");



ALTER TABLE ONLY "private"."unicode15_assigned_ranges"
    ADD CONSTRAINT "unicode15_assigned_ranges_pkey" PRIMARY KEY ("range_start");



ALTER TABLE ONLY "private"."unicode15_casefold"
    ADD CONSTRAINT "unicode15_casefold_pkey" PRIMARY KEY ("source_codepoint");



ALTER TABLE ONLY "public"."document_versions"
    ADD CONSTRAINT "document_versions_document_id_revision_key" UNIQUE ("document_id", "revision");



ALTER TABLE ONLY "public"."document_versions"
    ADD CONSTRAINT "document_versions_document_id_version_id_key" UNIQUE ("document_id", "version_id");



ALTER TABLE ONLY "public"."document_versions"
    ADD CONSTRAINT "document_versions_operation_id_key" UNIQUE ("operation_id");



ALTER TABLE ONLY "public"."document_versions"
    ADD CONSTRAINT "document_versions_pkey" PRIMARY KEY ("version_id");



ALTER TABLE "public"."documents"
    ADD CONSTRAINT "documents_contract_structure_revision_ck" CHECK ((("structure_revision" IS NULL) OR ("structure_revision" >= 1))) NOT VALID;



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_document_id_project_id_key" UNIQUE ("document_id", "project_id");



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_pkey" PRIMARY KEY ("document_id");



ALTER TABLE ONLY "public"."edit_leases"
    ADD CONSTRAINT "edit_leases_lease_token_key" UNIQUE ("lease_token");



ALTER TABLE ONLY "public"."edit_leases"
    ADD CONSTRAINT "edit_leases_pkey" PRIMARY KEY ("document_id");



ALTER TABLE ONLY "public"."folder_versions"
    ADD CONSTRAINT "folder_versions_folder_id_revision_key" UNIQUE ("folder_id", "revision");



ALTER TABLE ONLY "public"."folder_versions"
    ADD CONSTRAINT "folder_versions_folder_id_version_id_key" UNIQUE ("folder_id", "version_id");



ALTER TABLE ONLY "public"."folder_versions"
    ADD CONSTRAINT "folder_versions_operation_id_key" UNIQUE ("operation_id");



ALTER TABLE ONLY "public"."folder_versions"
    ADD CONSTRAINT "folder_versions_pkey" PRIMARY KEY ("version_id");



ALTER TABLE ONLY "public"."folders"
    ADD CONSTRAINT "folders_identity_project_uk" UNIQUE ("folder_id", "project_id");



ALTER TABLE ONLY "public"."folders"
    ADD CONSTRAINT "folders_pkey" PRIMARY KEY ("folder_id");



ALTER TABLE ONLY "public"."project_members"
    ADD CONSTRAINT "project_members_pkey" PRIMARY KEY ("project_id", "user_id");



ALTER TABLE ONLY "public"."project_sync_migrations"
    ADD CONSTRAINT "project_sync_migrations_pkey" PRIMARY KEY ("migration_id");



ALTER TABLE ONLY "public"."project_sync_migrations"
    ADD CONSTRAINT "project_sync_migrations_project_id_migration_epoch_key" UNIQUE ("project_id", "migration_epoch");



ALTER TABLE ONLY "public"."project_sync_settings"
    ADD CONSTRAINT "project_sync_settings_pkey" PRIMARY KEY ("project_id");



ALTER TABLE ONLY "public"."projects"
    ADD CONSTRAINT "projects_pkey" PRIMARY KEY ("project_id");



ALTER TABLE ONLY "public"."sync_batch_results"
    ADD CONSTRAINT "sync_batch_results_pkey" PRIMARY KEY ("batch_id");



ALTER TABLE ONLY "public"."sync_batches"
    ADD CONSTRAINT "sync_batches_pkey" PRIMARY KEY ("batch_id");



ALTER TABLE ONLY "public"."sync_operation_attempts"
    ADD CONSTRAINT "sync_operation_attempts_operation_id_attempt_number_key" UNIQUE ("operation_id", "attempt_number");



ALTER TABLE ONLY "public"."sync_operation_attempts"
    ADD CONSTRAINT "sync_operation_attempts_pkey" PRIMARY KEY ("attempt_id");



ALTER TABLE ONLY "public"."sync_operation_events"
    ADD CONSTRAINT "sync_operation_events_operation_id_event_sequence_key" UNIQUE ("operation_id", "event_sequence");



ALTER TABLE ONLY "public"."sync_operation_events"
    ADD CONSTRAINT "sync_operation_events_pkey" PRIMARY KEY ("event_id");



ALTER TABLE ONLY "public"."sync_operations"
    ADD CONSTRAINT "sync_operations_batch_id_sequence_key" UNIQUE ("batch_id", "sequence");



ALTER TABLE ONLY "public"."sync_operations"
    ADD CONSTRAINT "sync_operations_pkey" PRIMARY KEY ("operation_id");



ALTER TABLE ONLY "public"."tree_orders"
    ADD CONSTRAINT "tree_orders_pkey" PRIMARY KEY ("tree_order_id");



ALTER TABLE ONLY "public"."tree_orders"
    ADD CONSTRAINT "tree_orders_project_identity_uk" UNIQUE ("tree_order_id", "project_id");



CREATE INDEX "document_versions_project_created_idx" ON "public"."document_versions" USING "btree" ("project_id", "created_at", "document_id");



CREATE UNIQUE INDEX "documents_live_child_storage_name_uidx" ON "public"."documents" USING "btree" ("project_id", "parent_folder_id", "storage_name_key") WHERE (("parent_folder_id" IS NOT NULL) AND (NOT "is_deleted") AND ("storage_name_key" IS NOT NULL));



CREATE UNIQUE INDEX "documents_live_path_uidx" ON "public"."documents" USING "btree" ("project_id", "relative_path") WHERE (NOT "is_deleted");



CREATE UNIQUE INDEX "documents_live_root_storage_name_uidx" ON "public"."documents" USING "btree" ("project_id", "storage_name_key") WHERE (("parent_folder_id" IS NULL) AND (NOT "is_deleted") AND ("storage_name_key" IS NOT NULL));



CREATE INDEX "documents_project_revision_idx" ON "public"."documents" USING "btree" ("project_id", "revision");



CREATE INDEX "documents_project_updated_idx" ON "public"."documents" USING "btree" ("project_id", "updated_at", "document_id");



CREATE INDEX "edit_leases_expiry_idx" ON "public"."edit_leases" USING "btree" ("expires_at");



CREATE INDEX "folder_versions_project_created_idx" ON "public"."folder_versions" USING "btree" ("project_id", "created_at", "folder_id");



CREATE UNIQUE INDEX "folders_live_child_storage_name_uidx" ON "public"."folders" USING "btree" ("project_id", "parent_folder_id", "storage_name_key") WHERE (("parent_folder_id" IS NOT NULL) AND (NOT "is_deleted") AND ("storage_name_key" IS NOT NULL));



CREATE UNIQUE INDEX "folders_live_root_storage_name_uidx" ON "public"."folders" USING "btree" ("project_id", "storage_name_key") WHERE (("parent_folder_id" IS NULL) AND (NOT "is_deleted") AND ("storage_name_key" IS NOT NULL));



CREATE INDEX "folders_project_parent_idx" ON "public"."folders" USING "btree" ("project_id", "parent_folder_id", "folder_id");



CREATE INDEX "folders_project_revision_idx" ON "public"."folders" USING "btree" ("project_id", "revision", "folder_id");



CREATE INDEX "project_members_user_project_idx" ON "public"."project_members" USING "btree" ("user_id", "project_id");



CREATE UNIQUE INDEX "project_sync_migrations_active_uidx" ON "public"."project_sync_migrations" USING "btree" ("project_id") WHERE ("completed_at" IS NULL);



CREATE INDEX "projects_owner_trash_idx" ON "public"."projects" USING "btree" ("owner_id", "trashed_at", "project_id");



CREATE INDEX "sync_batches_project_created_idx" ON "public"."sync_batches" USING "btree" ("project_id", "created_at", "batch_id");



CREATE INDEX "sync_operation_attempts_operation_idx" ON "public"."sync_operation_attempts" USING "btree" ("operation_id", "attempt_number");



CREATE INDEX "sync_operation_events_operation_idx" ON "public"."sync_operation_events" USING "btree" ("operation_id", "event_sequence");



CREATE INDEX "sync_operations_project_created_idx" ON "public"."sync_operations" USING "btree" ("project_id", "created_at", "operation_id");



CREATE INDEX "sync_operations_supersedes_idx" ON "public"."sync_operations" USING "btree" ("supersedes_operation_id") WHERE ("supersedes_operation_id" IS NOT NULL);



CREATE UNIQUE INDEX "tree_orders_parent_uidx" ON "public"."tree_orders" USING "btree" ("project_id", "parent_folder_id") WHERE ("parent_folder_id" IS NOT NULL);



CREATE UNIQUE INDEX "tree_orders_root_uidx" ON "public"."tree_orders" USING "btree" ("project_id") WHERE ("parent_folder_id" IS NULL);



CREATE OR REPLACE TRIGGER "storage_name_v2_assigned_ranges_immutable" BEFORE DELETE OR UPDATE ON "private"."storage_name_v2_assigned_ranges" FOR EACH ROW EXECUTE FUNCTION "private"."reject_append_only_mutation"();



CREATE OR REPLACE TRIGGER "storage_name_v2_casefold_immutable" BEFORE DELETE OR UPDATE ON "private"."storage_name_v2_casefold" FOR EACH ROW EXECUTE FUNCTION "private"."reject_append_only_mutation"();



CREATE OR REPLACE TRIGGER "storage_name_v2_excluded_ranges_immutable" BEFORE DELETE OR UPDATE ON "private"."storage_name_v2_excluded_ranges" FOR EACH ROW EXECUTE FUNCTION "private"."reject_append_only_mutation"();



CREATE OR REPLACE TRIGGER "storage_name_v2_nonzero_ccc_immutable" BEFORE DELETE OR UPDATE ON "private"."storage_name_v2_nonzero_ccc" FOR EACH ROW EXECUTE FUNCTION "private"."reject_append_only_mutation"();



CREATE OR REPLACE TRIGGER "unicode15_assigned_ranges_immutable" BEFORE DELETE OR UPDATE ON "private"."unicode15_assigned_ranges" FOR EACH ROW EXECUTE FUNCTION "private"."reject_append_only_mutation"();



CREATE OR REPLACE TRIGGER "unicode15_casefold_immutable" BEFORE DELETE OR UPDATE ON "private"."unicode15_casefold" FOR EACH ROW EXECUTE FUNCTION "private"."reject_append_only_mutation"();



CREATE OR REPLACE TRIGGER "document_versions_contract_boundary" BEFORE INSERT ON "public"."document_versions" FOR EACH ROW EXECUTE FUNCTION "private"."enforce_document_write_boundary"();



CREATE OR REPLACE TRIGGER "sync_batch_results_append_only" BEFORE DELETE OR UPDATE ON "public"."sync_batch_results" FOR EACH ROW EXECUTE FUNCTION "private"."reject_append_only_mutation"();



CREATE OR REPLACE TRIGGER "sync_batches_append_only" BEFORE DELETE OR UPDATE ON "public"."sync_batches" FOR EACH ROW EXECUTE FUNCTION "private"."reject_append_only_mutation"();



CREATE OR REPLACE TRIGGER "sync_operation_attempts_append_only" BEFORE DELETE OR UPDATE ON "public"."sync_operation_attempts" FOR EACH ROW EXECUTE FUNCTION "private"."reject_append_only_mutation"();



CREATE OR REPLACE TRIGGER "sync_operation_events_append_only" BEFORE DELETE OR UPDATE ON "public"."sync_operation_events" FOR EACH ROW EXECUTE FUNCTION "private"."reject_append_only_mutation"();



CREATE OR REPLACE TRIGGER "sync_operations_append_only" BEFORE DELETE OR UPDATE ON "public"."sync_operations" FOR EACH ROW EXECUTE FUNCTION "private"."reject_append_only_mutation"();



ALTER TABLE ONLY "public"."document_versions"
    ADD CONSTRAINT "document_versions_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."document_versions"
    ADD CONSTRAINT "document_versions_document_fk" FOREIGN KEY ("document_id", "project_id") REFERENCES "public"."documents"("document_id", "project_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_current_version_fk" FOREIGN KEY ("document_id", "current_version_id") REFERENCES "public"."document_versions"("document_id", "version_id") DEFERRABLE INITIALLY DEFERRED;



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_parent_folder_fk" FOREIGN KEY ("parent_folder_id", "project_id") REFERENCES "public"."folders"("folder_id", "project_id") DEFERRABLE INITIALLY DEFERRED;



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("project_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."edit_leases"
    ADD CONSTRAINT "edit_leases_document_id_fkey" FOREIGN KEY ("document_id") REFERENCES "public"."documents"("document_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."edit_leases"
    ADD CONSTRAINT "edit_leases_holder_user_id_fkey" FOREIGN KEY ("holder_user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."folder_versions"
    ADD CONSTRAINT "folder_versions_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."folder_versions"
    ADD CONSTRAINT "folder_versions_folder_fk" FOREIGN KEY ("folder_id", "project_id") REFERENCES "public"."folders"("folder_id", "project_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."folders"
    ADD CONSTRAINT "folders_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."folders"
    ADD CONSTRAINT "folders_current_version_fk" FOREIGN KEY ("folder_id", "current_version_id") REFERENCES "public"."folder_versions"("folder_id", "version_id") DEFERRABLE INITIALLY DEFERRED;



ALTER TABLE ONLY "public"."folders"
    ADD CONSTRAINT "folders_parent_fk" FOREIGN KEY ("parent_folder_id", "project_id") REFERENCES "public"."folders"("folder_id", "project_id") DEFERRABLE INITIALLY DEFERRED;



ALTER TABLE ONLY "public"."folders"
    ADD CONSTRAINT "folders_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("project_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."folders"
    ADD CONSTRAINT "folders_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."project_members"
    ADD CONSTRAINT "project_members_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("project_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_members"
    ADD CONSTRAINT "project_members_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_sync_migrations"
    ADD CONSTRAINT "project_sync_migrations_completed_by_user_id_fkey" FOREIGN KEY ("completed_by_user_id") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."project_sync_migrations"
    ADD CONSTRAINT "project_sync_migrations_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("project_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."project_sync_migrations"
    ADD CONSTRAINT "project_sync_migrations_started_by_user_id_fkey" FOREIGN KEY ("started_by_user_id") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."project_sync_migrations"
    ADD CONSTRAINT "project_sync_migrations_target_contract_sha256_fkey" FOREIGN KEY ("target_contract_sha256") REFERENCES "private"."sync_contract_allowlist"("canonical_contract_sha256");



ALTER TABLE ONLY "public"."project_sync_settings"
    ADD CONSTRAINT "project_sync_settings_active_contract_sha256_fkey" FOREIGN KEY ("active_contract_sha256") REFERENCES "private"."sync_contract_allowlist"("canonical_contract_sha256");



ALTER TABLE ONLY "public"."project_sync_settings"
    ADD CONSTRAINT "project_sync_settings_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("project_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."projects"
    ADD CONSTRAINT "projects_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."projects"
    ADD CONSTRAINT "projects_trashed_by_fkey" FOREIGN KEY ("trashed_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."sync_batch_results"
    ADD CONSTRAINT "sync_batch_results_batch_id_fkey" FOREIGN KEY ("batch_id") REFERENCES "public"."sync_batches"("batch_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sync_batches"
    ADD CONSTRAINT "sync_batches_canonical_contract_sha256_fkey" FOREIGN KEY ("canonical_contract_sha256") REFERENCES "private"."sync_contract_allowlist"("canonical_contract_sha256");



ALTER TABLE ONLY "public"."sync_batches"
    ADD CONSTRAINT "sync_batches_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("project_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sync_batches"
    ADD CONSTRAINT "sync_batches_writer_user_id_fkey" FOREIGN KEY ("writer_user_id") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."sync_operation_attempts"
    ADD CONSTRAINT "sync_operation_attempts_operation_id_fkey" FOREIGN KEY ("operation_id") REFERENCES "public"."sync_operations"("operation_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sync_operation_events"
    ADD CONSTRAINT "sync_operation_events_operation_id_fkey" FOREIGN KEY ("operation_id") REFERENCES "public"."sync_operations"("operation_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sync_operations"
    ADD CONSTRAINT "sync_operations_batch_id_fkey" FOREIGN KEY ("batch_id") REFERENCES "public"."sync_batches"("batch_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."sync_operations"
    ADD CONSTRAINT "sync_operations_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."sync_operations"
    ADD CONSTRAINT "sync_operations_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("project_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sync_operations"
    ADD CONSTRAINT "sync_operations_supersedes_operation_id_fkey" FOREIGN KEY ("supersedes_operation_id") REFERENCES "public"."sync_operations"("operation_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."tree_orders"
    ADD CONSTRAINT "tree_orders_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."tree_orders"
    ADD CONSTRAINT "tree_orders_parent_fk" FOREIGN KEY ("parent_folder_id", "project_id") REFERENCES "public"."folders"("folder_id", "project_id") DEFERRABLE INITIALLY DEFERRED;



ALTER TABLE ONLY "public"."tree_orders"
    ADD CONSTRAINT "tree_orders_project_id_fkey" FOREIGN KEY ("project_id") REFERENCES "public"."projects"("project_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."tree_orders"
    ADD CONSTRAINT "tree_orders_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE "private"."project_purge_tombstones" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."document_versions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "document_versions_read_members" ON "public"."document_versions" FOR SELECT TO "authenticated" USING ("private"."has_project_role"("project_id", ( SELECT "auth"."uid"() AS "uid"), 'viewer'::"text"));



ALTER TABLE "public"."documents" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "documents_read_members" ON "public"."documents" FOR SELECT TO "authenticated" USING ("private"."has_project_role"("project_id", ( SELECT "auth"."uid"() AS "uid"), 'viewer'::"text"));



ALTER TABLE "public"."edit_leases" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."folder_versions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "folder_versions_read_members" ON "public"."folder_versions" FOR SELECT TO "authenticated" USING ("private"."has_project_role"("project_id", ( SELECT "auth"."uid"() AS "uid"), 'viewer'::"text"));



ALTER TABLE "public"."folders" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "folders_read_members" ON "public"."folders" FOR SELECT TO "authenticated" USING ("private"."has_project_role"("project_id", ( SELECT "auth"."uid"() AS "uid"), 'viewer'::"text"));



ALTER TABLE "public"."project_members" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "project_members_read_members" ON "public"."project_members" FOR SELECT TO "authenticated" USING ("private"."has_project_role"("project_id", ( SELECT "auth"."uid"() AS "uid"), 'viewer'::"text"));



ALTER TABLE "public"."project_sync_migrations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "project_sync_migrations_read_members" ON "public"."project_sync_migrations" FOR SELECT TO "authenticated" USING ("private"."has_project_role"("project_id", ( SELECT "auth"."uid"() AS "uid"), 'viewer'::"text"));



ALTER TABLE "public"."project_sync_settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "project_sync_settings_read_members" ON "public"."project_sync_settings" FOR SELECT TO "authenticated" USING ("private"."has_project_role"("project_id", ( SELECT "auth"."uid"() AS "uid"), 'viewer'::"text"));



ALTER TABLE "public"."projects" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "projects_read_members" ON "public"."projects" FOR SELECT TO "authenticated" USING ("private"."has_project_role"("project_id", ( SELECT "auth"."uid"() AS "uid"), 'viewer'::"text"));



ALTER TABLE "public"."sync_batch_results" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sync_batch_results_read_members" ON "public"."sync_batch_results" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."sync_batches" "batch"
  WHERE (("batch"."batch_id" = "sync_batch_results"."batch_id") AND "private"."has_project_role"("batch"."project_id", ( SELECT "auth"."uid"() AS "uid"), 'viewer'::"text")))));



ALTER TABLE "public"."sync_batches" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sync_batches_read_members" ON "public"."sync_batches" FOR SELECT TO "authenticated" USING ("private"."has_project_role"("project_id", ( SELECT "auth"."uid"() AS "uid"), 'viewer'::"text"));



ALTER TABLE "public"."sync_operation_attempts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sync_operation_attempts_read_members" ON "public"."sync_operation_attempts" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."sync_operations" "operation"
  WHERE (("operation"."operation_id" = "sync_operation_attempts"."operation_id") AND "private"."has_project_role"("operation"."project_id", ( SELECT "auth"."uid"() AS "uid"), 'viewer'::"text")))));



ALTER TABLE "public"."sync_operation_events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sync_operation_events_read_members" ON "public"."sync_operation_events" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."sync_operations" "operation"
  WHERE (("operation"."operation_id" = "sync_operation_events"."operation_id") AND "private"."has_project_role"("operation"."project_id", ( SELECT "auth"."uid"() AS "uid"), 'viewer'::"text")))));



ALTER TABLE "public"."sync_operations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sync_operations_read_members" ON "public"."sync_operations" FOR SELECT TO "authenticated" USING ("private"."has_project_role"("project_id", ( SELECT "auth"."uid"() AS "uid"), 'viewer'::"text"));



ALTER TABLE "public"."tree_orders" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tree_orders_read_members" ON "public"."tree_orders" FOR SELECT TO "authenticated" USING ("private"."has_project_role"("project_id", ( SELECT "auth"."uid"() AS "uid"), 'viewer'::"text"));



GRANT USAGE ON SCHEMA "private" TO "authenticated";



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



REVOKE ALL ON FUNCTION "private"."append_operation_event"("p_operation_id" "uuid", "p_event_id" "uuid", "p_event_type" "text", "p_error_code" "text", "p_blocking_operation_id" "uuid", "p_detail" "jsonb") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."apply_structure_intent"("p_project_id" "uuid", "p_user_id" "uuid", "p_intent" "jsonb") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."atomic_failure"("p_batch_id" "uuid", "p_batch_payload_sha256" "text", "p_code" "text", "p_message" "text", "p_failed_sequence" integer) FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."content_sha256"("p_content" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."default_casefold_unicode15"("p_value" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."document_failure"("p_batch_id" "uuid", "p_batch_payload_sha256" "text", "p_code" "text", "p_message" "text", "p_failed_sequence" integer) FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."document_relative_path"("p_project_id" "uuid", "p_parent_folder_id" "uuid", "p_name" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."enforce_document_write_boundary"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."has_project_role"("p_project_id" "uuid", "p_user_id" "uuid", "p_minimum_role" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."has_project_role"("p_project_id" "uuid", "p_user_id" "uuid", "p_minimum_role" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "private"."is_valid_entry_name"("p_name" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."is_valid_relative_path"("p_path" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."jsonb_rfc8785_sha256"("p_value" "jsonb") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."nfkc_unicode15"("p_value" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."rfc8785_canonical_json"("p_value" "jsonb") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."storage_name_v1"("p_name" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."storage_name_v1_legacy"("p_name" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."storage_name_v1_result"("p_name" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."storage_name_v1_text"("p_name" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."storage_name_v2"("p_name" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."storage_name_v2_is_assigned"("p_codepoint" integer) FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."storage_name_v2_is_excluded"("p_codepoint" integer) FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."storage_name_v2_result"("p_name" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."unicode15_is_assigned"("p_codepoint" integer) FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."validate_contract_request"("p_user_id" "uuid", "p_project_id" "uuid", "p_project_sync_mode" "text", "p_migration_epoch" integer, "p_batch" "jsonb", "p_ordered_intents" "jsonb") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."acquire_edit_lease"("p_document_id" "uuid", "p_device_id" "uuid", "p_ttl_seconds" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."acquire_edit_lease"("p_document_id" "uuid", "p_device_id" "uuid", "p_ttl_seconds" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."acquire_edit_lease"("p_document_id" "uuid", "p_device_id" "uuid", "p_ttl_seconds" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."atomic_structure_commit"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."atomic_structure_commit"("p_request" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."atomic_structure_commit"("p_request" "jsonb") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."atomic_structure_commit_legacy"("p_request" "jsonb") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."begin_project_sync_migration"("p_project_id" "uuid", "p_writer_device_id" "uuid", "p_target_contract_sha256" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."begin_project_sync_migration"("p_project_id" "uuid", "p_writer_device_id" "uuid", "p_target_contract_sha256" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."cancel_sync_operation"("p_operation_id" "uuid", "p_cancel_event_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cancel_sync_operation"("p_operation_id" "uuid", "p_cancel_event_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."commit_document"("p_document_id" "uuid", "p_project_id" "uuid", "p_base_revision" bigint, "p_operation_id" "uuid", "p_device_id" "uuid", "p_relative_path" "text", "p_content" "text", "p_is_deleted" boolean, "p_lease_token" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."commit_document"("p_document_id" "uuid", "p_project_id" "uuid", "p_base_revision" bigint, "p_operation_id" "uuid", "p_device_id" "uuid", "p_relative_path" "text", "p_content" "text", "p_is_deleted" boolean, "p_lease_token" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."commit_document"("p_document_id" "uuid", "p_project_id" "uuid", "p_base_revision" bigint, "p_operation_id" "uuid", "p_device_id" "uuid", "p_relative_path" "text", "p_content" "text", "p_is_deleted" boolean, "p_lease_token" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."commit_folder"("p_folder_id" "uuid", "p_project_id" "uuid", "p_base_revision" bigint, "p_operation_id" "uuid", "p_device_id" "uuid", "p_parent_folder_id" "uuid", "p_name" "text", "p_is_deleted" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."commit_folder"("p_folder_id" "uuid", "p_project_id" "uuid", "p_base_revision" bigint, "p_operation_id" "uuid", "p_device_id" "uuid", "p_parent_folder_id" "uuid", "p_name" "text", "p_is_deleted" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."commit_folder"("p_folder_id" "uuid", "p_project_id" "uuid", "p_base_revision" bigint, "p_operation_id" "uuid", "p_device_id" "uuid", "p_parent_folder_id" "uuid", "p_name" "text", "p_is_deleted" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."complete_project_sync_migration"("p_project_id" "uuid", "p_writer_device_id" "uuid", "p_migration_epoch" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."complete_project_sync_migration"("p_project_id" "uuid", "p_writer_device_id" "uuid", "p_migration_epoch" integer) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."document_commit"("p_request" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."document_commit"("p_request" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."document_commit"("p_request" "jsonb") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."document_commit_legacy"("p_request" "jsonb") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."ensure_project"("p_project_id" "uuid", "p_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ensure_project"("p_project_id" "uuid", "p_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ensure_project"("p_project_id" "uuid", "p_name" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_edit_lease"("p_document_id" "uuid", "p_device_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_edit_lease"("p_document_id" "uuid", "p_device_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_edit_lease"("p_document_id" "uuid", "p_device_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_project_status"("p_project_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_project_status"("p_project_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_project_status"("p_project_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_sync_handshake"("p_project_id" "uuid", "p_contract_sha256" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_sync_handshake"("p_project_id" "uuid", "p_contract_sha256" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."list_trashed_projects"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."list_trashed_projects"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."list_trashed_projects"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."purge_project"("p_project_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."purge_project"("p_project_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."purge_project"("p_project_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."release_edit_lease"("p_document_id" "uuid", "p_device_id" "uuid", "p_lease_token" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."release_edit_lease"("p_document_id" "uuid", "p_device_id" "uuid", "p_lease_token" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."release_edit_lease"("p_document_id" "uuid", "p_device_id" "uuid", "p_lease_token" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."renew_edit_lease"("p_document_id" "uuid", "p_device_id" "uuid", "p_lease_token" "uuid", "p_ttl_seconds" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."renew_edit_lease"("p_document_id" "uuid", "p_device_id" "uuid", "p_lease_token" "uuid", "p_ttl_seconds" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."renew_edit_lease"("p_document_id" "uuid", "p_device_id" "uuid", "p_lease_token" "uuid", "p_ttl_seconds" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."restore_project"("p_project_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."restore_project"("p_project_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."restore_project"("p_project_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."trash_project"("p_project_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."trash_project"("p_project_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."trash_project"("p_project_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."validate_project_sync_migration"("p_project_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."validate_project_sync_migration"("p_project_id" "uuid") TO "authenticated";



GRANT ALL ON TABLE "public"."document_versions" TO "service_role";
GRANT SELECT ON TABLE "public"."document_versions" TO "authenticated";



GRANT ALL ON TABLE "public"."documents" TO "service_role";
GRANT SELECT ON TABLE "public"."documents" TO "authenticated";



GRANT ALL ON TABLE "public"."edit_leases" TO "service_role";



GRANT ALL ON TABLE "public"."folder_versions" TO "service_role";
GRANT SELECT ON TABLE "public"."folder_versions" TO "authenticated";



GRANT ALL ON TABLE "public"."folders" TO "service_role";
GRANT SELECT ON TABLE "public"."folders" TO "authenticated";



GRANT ALL ON TABLE "public"."project_members" TO "service_role";
GRANT SELECT ON TABLE "public"."project_members" TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."project_sync_migrations" TO "service_role";
GRANT SELECT ON TABLE "public"."project_sync_migrations" TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."project_sync_settings" TO "service_role";
GRANT SELECT ON TABLE "public"."project_sync_settings" TO "authenticated";



GRANT ALL ON TABLE "public"."projects" TO "service_role";
GRANT SELECT ON TABLE "public"."projects" TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."sync_batch_results" TO "service_role";
GRANT SELECT ON TABLE "public"."sync_batch_results" TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."sync_batches" TO "service_role";
GRANT SELECT ON TABLE "public"."sync_batches" TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."sync_operation_attempts" TO "service_role";
GRANT SELECT ON TABLE "public"."sync_operation_attempts" TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."sync_operation_events" TO "service_role";
GRANT SELECT ON TABLE "public"."sync_operation_events" TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."sync_operations" TO "service_role";
GRANT SELECT ON TABLE "public"."sync_operations" TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."sync_operation_states" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."sync_operation_states" TO "authenticated";
GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."sync_operation_states" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."tree_orders" TO "service_role";
GRANT SELECT ON TABLE "public"."tree_orders" TO "authenticated";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "service_role";







