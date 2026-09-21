-- 고정 UUID의 내부 제어 문서는 원고 이름을 갖지 않으므로 전환 검사에서 분리한다.
begin;

create or replace function private.is_contract_migration_control_document(p_document public.documents)
returns boolean language plpgsql immutable security invoker set search_path = '' as $$
declare
  v_hash bytea;
  v_expected uuid;
begin
  if p_document.project_id is null or p_document.document_id is null
     or p_document.relative_path is null
     or p_document.relative_path not in ('__antigravity__/tree-order.json', '__antigravity__/trash-purge.json')
     or p_document.name is not null or p_document.parent_folder_id is not null
     or p_document.structure_revision is not null or p_document.storage_name_key is not null then
    return false;
  end if;
  v_hash := extensions.digest(pg_catalog.uuid_send(p_document.project_id) || pg_catalog.convert_to(p_document.relative_path, 'UTF8'), 'sha1');
  v_hash := pg_catalog.set_byte(v_hash, 6, (pg_catalog.get_byte(v_hash, 6) & 15) | 80);
  v_hash := pg_catalog.set_byte(v_hash, 8, (pg_catalog.get_byte(v_hash, 8) & 63) | 128);
  v_expected := pg_catalog.encode(pg_catalog.substring(v_hash, 1, 16), 'hex')::uuid;
  return p_document.document_id = v_expected;
end;
$$;
revoke all on function private.is_contract_migration_control_document(public.documents) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.validate_project_sync_migration(p_project_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  from public.documents d
  where d.project_id = p_project_id and not d.is_deleted
    and pg_catalog.split_part(d.relative_path, '/', 1) = '__antigravity__'
    and not private.is_contract_migration_control_document(d);
  if v_count > 0 then
    v_issues := v_issues || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'INVALID_CONTROL_DOCUMENT', 'count', v_count)
    );
  end if;

  select count(*) into v_count
  from (
    select name from public.folders
    where project_id = p_project_id and not is_deleted
    union all
    select d.name from public.documents d
    where d.project_id = p_project_id and not d.is_deleted
      and not private.is_contract_migration_control_document(d)
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
$function$;

CREATE OR REPLACE FUNCTION public.complete_project_sync_migration(p_project_id uuid, p_writer_device_id uuid, p_migration_epoch integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  update public.documents d
  set storage_name_key = private.storage_name_v1(d.name)
  where d.project_id = p_project_id and not d.is_deleted
    and not private.is_contract_migration_control_document(d);

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
$function$;

-- CREATE OR REPLACE는 기존 ACL을 보존하지만 공개 SECURITY DEFINER 경계를
-- migration 자체에서도 명시적으로 재확인한다.
revoke all on function public.validate_project_sync_migration(uuid) from public, anon;
revoke all on function public.complete_project_sync_migration(uuid, uuid, integer) from public, anon;
grant execute on function public.validate_project_sync_migration(uuid) to authenticated;
grant execute on function public.complete_project_sync_migration(uuid, uuid, integer) to authenticated;

commit;
