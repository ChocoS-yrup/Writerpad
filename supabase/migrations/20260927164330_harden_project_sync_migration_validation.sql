-- Strengthen the existing explicit migration gate, without promoting projects,
-- changing wire pins, repairing data, or rewriting historical migrations.
begin;

create or replace function public.validate_project_sync_migration(p_project_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_contract_sha256 text;
  v_issues jsonb := '[]'::jsonb;
  v_count bigint;
  v_duplicate_count bigint;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if not private.has_project_role(p_project_id, v_user_id, 'editor') then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  -- Share the begin/complete/contract-write lock even for a standalone check.
  -- Complete already holds it; transaction advisory locks are reentrant.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('project:' || p_project_id::text, 0)
  );

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
  perform pg_catalog.set_config('writerpad.contract_sha256', v_contract_sha256, true);

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

  -- FKs only guarantee a row exists; a deleted parent is not a live parent.
  select count(*) into v_count
  from (
    select parent_folder_id from public.folders
    where project_id = p_project_id and not is_deleted
    union all
    select d.parent_folder_id from public.documents d
    where d.project_id = p_project_id and not d.is_deleted
      and not private.is_contract_migration_control_document(d)
  ) child
  where child.parent_folder_id is not null
    and not exists (
      select 1 from public.folders parent
      where parent.project_id = p_project_id
        and parent.folder_id = child.parent_folder_id and not parent.is_deleted
    );
  if v_count > 0 then
    v_issues := v_issues || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'FOLDER_NOT_FOUND', 'count', v_count)
    );
  else
    -- Each live folder has one parent. With all parents resolved, any folder
    -- unreachable from a null-parent root has cyclic ancestry. Traversing only
    -- roots cannot enter a cycle and avoids an O(depth^2) path array per folder.
    with recursive rooted(folder_id) as (
      select folder_id from public.folders
      where project_id = p_project_id and not is_deleted and parent_folder_id is null
      union all
      select child.folder_id
      from public.folders child join rooted parent on child.parent_folder_id = parent.folder_id
      where child.project_id = p_project_id and not child.is_deleted
    )
    select count(*) into v_count
    from public.folders f
    where f.project_id = p_project_id and not f.is_deleted
      and not exists (select 1 from rooted r where r.folder_id = f.folder_id);
    if v_count > 0 then
      v_issues := v_issues || pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('code', 'FOLDER_CYCLE', 'count', v_count)
      );
    end if;
  end if;

  -- Validate references that exist. Do not invent a requirement to materialize
  -- an order row for every empty folder or to list every naturally sorted child.
  -- Reserved control documents are not binder entities, even when valid.
  with live_entities as materialized (
    select folder_id as entity_id, parent_folder_id from public.folders
    where project_id = p_project_id and not is_deleted
    union all
    select d.document_id, d.parent_folder_id from public.documents d
    where d.project_id = p_project_id and not d.is_deleted
      and not private.is_contract_migration_control_document(d)
  ), checked as (
    select
      (coalesce(pg_catalog.array_ndims(t.children), 1) <> 1
       or (t.parent_folder_id is not null and not exists (
         select 1 from public.folders f where f.project_id = p_project_id
           and f.folder_id = t.parent_folder_id and not f.is_deleted
       ))
       or exists (
         select 1 from pg_catalog.unnest(t.children) child(id)
         where child.id is null or not exists (
           select 1 from live_entities e where e.entity_id = child.id
             and e.parent_folder_id is not distinct from t.parent_folder_id
         )
       )) as invalid_reference,
      (exists (
         select 1 from pg_catalog.unnest(t.children) child(id)
         where child.id is not null group by child.id having count(*) > 1
       ) or exists (
         select 1 from live_entities e
         where e.entity_id = any(t.children)
         group by e.entity_id having count(*) > 1
       )) as duplicated_reference
    from public.tree_orders t where t.project_id = p_project_id
  )
  select count(*) filter (where invalid_reference),
         count(*) filter (where duplicated_reference)
  into v_count, v_duplicate_count from checked;
  if v_count > 0 then
    v_issues := v_issues || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'TREE_REFERENCE_NOT_FOUND', 'count', v_count)
    );
  end if;
  if v_duplicate_count > 0 then
    v_issues := v_issues || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'TREE_REFERENCE_DUPLICATED', 'count', v_duplicate_count)
    );
  end if;

  select count(*) into v_count
  from (
    select parent_folder_id, private.storage_name_v1(name) as collision_key
    from public.folders
    where project_id = p_project_id and not is_deleted
      and (private.storage_name_v1_result(name)->>'valid')::boolean
    union all
    select parent_folder_id, private.storage_name_v1(name) as collision_key
    from public.documents
    where project_id = p_project_id and not is_deleted and name is not null
      and (private.storage_name_v1_result(name)->>'valid')::boolean
  ) names
  group by parent_folder_id, collision_key
  having count(*) > 1 limit 1;
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

revoke all on function public.validate_project_sync_migration(uuid) from public, anon;
grant execute on function public.validate_project_sync_migration(uuid) to authenticated;

commit;
