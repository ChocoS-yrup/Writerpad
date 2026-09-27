\set ON_ERROR_STOP on

-- Isolated PostgreSQL CI only. All synthetic identities, data and helper
-- functions are rolled back; never run this fixture against a deployed DB.
begin;
set local statement_timeout = '30s';

insert into auth.users(id) values
  ('98000000-0000-4000-8000-000000000001'),
  ('98000000-0000-4000-8000-000000000002'),
  ('98000000-0000-4000-8000-000000000003'),
  ('98000000-0000-4000-8000-000000000004');
update private.sync_contract_allowlist set enabled = true
where canonical_contract_sha256 =
  '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670';
select set_config('request.jwt.claim.sub', '98000000-0000-4000-8000-000000000001', true);

create function pg_temp.migration_fingerprint(p_project uuid) returns jsonb
language sql set search_path = '' as $$
  select jsonb_build_object(
    'settings', (select to_jsonb(s) from public.project_sync_settings s where project_id = p_project),
    'folders', (select jsonb_agg(to_jsonb(f) order by folder_id) from public.folders f where project_id = p_project),
    'documents', (select jsonb_agg(to_jsonb(d) order by document_id) from public.documents d where project_id = p_project),
    'tree_orders', (select jsonb_agg(to_jsonb(t) order by tree_order_id) from public.tree_orders t where project_id = p_project)
  );
$$;

create function pg_temp.expect_migration_error(p_call text, p_error text) returns void
language plpgsql as $$
begin
  begin
    set local role authenticated;
    execute p_call;
    reset role;
  exception when sqlstate 'P0001' then
    if sqlerrm is distinct from p_error then
      raise exception using errcode = 'XX001', message = 'wrong error: ' || sqlerrm || ', expected ' || p_error;
    end if;
    return;
  end;
  raise exception using errcode = 'XX001', message = 'expected rejection: ' || p_error;
end;
$$;

-- Exercise the real public RPCs as authenticated, not as database owner.
-- The owner role only constructs fixtures and independently verifies storage.
do $cases$
declare
  v_owner constant uuid := '98000000-0000-4000-8000-000000000001';
  v_device constant uuid := '68000000-0000-4000-8000-000000000001';
  v_digest constant text := '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670';
  v_case text;
  v_project uuid;
  v_other_project uuid;
  v_a uuid;
  v_b uuid;
  v_dead uuid;
  v_doc uuid;
  v_control uuid;
  v_tree uuid;
  v_other uuid;
  v_hash bytea;
  v_expected text[];
  v_codes text[];
  v_before jsonb;
  v_audit_before jsonb;
  v_result jsonb;
  v_validation jsonb;
  v_i integer;
  v_parent uuid;
  v_child uuid;
begin
  foreach v_case in array array[
    'valid', 'empty', 'partial_order', 'no_orders', 'deep_acyclic',
    'document_deleted_parent', 'folder_deleted_parent', 'two_folder_cycle', 'cycle_with_descendant',
    'unknown_reference', 'deleted_folder_reference', 'deleted_document_reference',
    'wrong_project_reference', 'wrong_parent_reference', 'deleted_order_parent',
    'duplicate_reference', 'ambiguous_identity', 'null_reference', 'multidimensional_order',
    'control_reference', 'control_wrong_uuid', 'control_invalid_metadata',
    'invalid_storage_name', 'sibling_collision', 'valid_v2_contract'
  ] loop
    v_project := gen_random_uuid(); v_other_project := gen_random_uuid();
    v_a := gen_random_uuid(); v_b := gen_random_uuid(); v_dead := gen_random_uuid();
    v_doc := gen_random_uuid(); v_tree := gen_random_uuid(); v_other := gen_random_uuid();
    v_expected := '{}'::text[];
    insert into public.projects(project_id, owner_id, name)
    values (v_project, v_owner, 'migration validation ' || v_case),
           (v_other_project, v_owner, 'unrelated synthetic project');
    insert into public.project_members(project_id, user_id, role)
    values (v_project, v_owner, 'owner');
    insert into public.folders(folder_id, project_id, parent_folder_id, name, revision,
                               is_deleted, deleted_at, created_by, updated_by)
    values (v_a, v_project, null, 'root', 1, false, null, v_owner, v_owner),
           (v_b, v_project, v_a, 'child', 1, false, null, v_owner, v_owner),
           (v_dead, v_project, null, 'tombstone', 2, true, now(), v_owner, v_owner),
           (v_other, v_other_project, null, 'unrelated', 1, false, null, v_owner, v_owner);
    insert into public.documents(document_id, project_id, parent_folder_id, name, structure_revision,
                                 relative_path, content, revision, created_by, updated_by)
    values (v_doc, v_project, v_a, 'chapter.txt', 1, 'root/chapter.txt', 'test body', 1, v_owner, v_owner);
    insert into public.tree_orders(tree_order_id, project_id, parent_folder_id, children,
                                   revision, created_by, updated_by)
    values (v_tree, v_project, v_a, array[v_b, v_doc], 1, v_owner, v_owner),
           (gen_random_uuid(), v_project, null, array[v_a], 1, v_owner, v_owner),
           (gen_random_uuid(), v_project, v_b, '{}'::uuid[], 1, v_owner, v_owner),
           -- Invalid references in another project must not contaminate this result.
           (gen_random_uuid(), v_other_project, null, array[gen_random_uuid()], 1, v_owner, v_owner);

    -- Both reserved controls must retain their existing narrow UUID-v5 exception.
    v_hash := extensions.digest(uuid_send(v_project) || convert_to('__antigravity__/tree-order.json', 'UTF8'), 'sha1');
    v_hash := set_byte(v_hash, 6, (get_byte(v_hash, 6) & 15) | 80);
    v_hash := set_byte(v_hash, 8, (get_byte(v_hash, 8) & 63) | 128);
    v_control := encode(substring(v_hash, 1, 16), 'hex')::uuid;
    insert into public.documents(document_id, project_id, relative_path, content, revision, created_by, updated_by)
    values (v_control, v_project, '__antigravity__/tree-order.json', '{"version":1}', 1, v_owner, v_owner);
    v_hash := extensions.digest(uuid_send(v_project) || convert_to('__antigravity__/trash-purge.json', 'UTF8'), 'sha1');
    v_hash := set_byte(v_hash, 6, (get_byte(v_hash, 6) & 15) | 80);
    v_hash := set_byte(v_hash, 8, (get_byte(v_hash, 8) & 63) | 128);
    insert into public.documents(document_id, project_id, relative_path, content, revision, created_by, updated_by)
    values (encode(substring(v_hash, 1, 16), 'hex')::uuid, v_project,
            '__antigravity__/trash-purge.json', '{"version":1}', 1, v_owner, v_owner);

    case v_case
      when 'empty' then
        delete from public.tree_orders where project_id = v_project;
        delete from public.documents where project_id = v_project;
        delete from public.folders where project_id = v_project;
      when 'partial_order' then
        update public.tree_orders set children = array[v_b] where tree_order_id = v_tree;
      when 'no_orders' then
        delete from public.tree_orders where project_id = v_project;
      when 'deep_acyclic' then
        v_parent := v_b;
        for v_i in 1..250 loop
          v_child := gen_random_uuid();
          insert into public.folders(folder_id, project_id, parent_folder_id, name, revision, created_by, updated_by)
          values (v_child, v_project, v_parent, 'deep-' || v_i, 1, v_owner, v_owner);
          v_parent := v_child;
        end loop;
      when 'document_deleted_parent' then
        update public.documents set parent_folder_id = v_dead where document_id = v_doc;
        delete from public.tree_orders where project_id = v_project;
        v_expected := array['FOLDER_NOT_FOUND'];
      when 'folder_deleted_parent' then
        update public.folders set parent_folder_id = v_dead where folder_id = v_b;
        delete from public.tree_orders where project_id = v_project;
        v_expected := array['FOLDER_NOT_FOUND'];
      when 'two_folder_cycle', 'cycle_with_descendant' then
        update public.folders set parent_folder_id = v_b where folder_id = v_a;
        delete from public.tree_orders where project_id = v_project;
        if v_case = 'cycle_with_descendant' then
          insert into public.folders(folder_id, project_id, parent_folder_id, name, revision, created_by, updated_by)
          values (gen_random_uuid(), v_project, v_b, 'cycle descendant', 1, v_owner, v_owner);
        end if;
        v_expected := array['FOLDER_CYCLE'];
      when 'unknown_reference' then
        update public.tree_orders set children = array[gen_random_uuid()] where tree_order_id = v_tree;
        v_expected := array['TREE_REFERENCE_NOT_FOUND'];
      when 'deleted_folder_reference' then
        update public.tree_orders set children = array[v_dead] where tree_order_id = v_tree;
        v_expected := array['TREE_REFERENCE_NOT_FOUND'];
      when 'deleted_document_reference' then
        update public.documents set is_deleted = true, deleted_at = now(), revision = 2 where document_id = v_doc;
        v_expected := array['TREE_REFERENCE_NOT_FOUND'];
      when 'wrong_project_reference' then
        update public.tree_orders set children = array[v_other] where tree_order_id = v_tree;
        v_expected := array['TREE_REFERENCE_NOT_FOUND'];
      when 'wrong_parent_reference' then
        update public.tree_orders set children = array[v_a] where tree_order_id = v_tree;
        v_expected := array['TREE_REFERENCE_NOT_FOUND'];
      when 'deleted_order_parent' then
        update public.tree_orders set parent_folder_id = v_dead, children = '{}' where tree_order_id = v_tree;
        v_expected := array['TREE_REFERENCE_NOT_FOUND'];
      when 'duplicate_reference' then
        update public.tree_orders set children = array[v_doc, v_doc] where tree_order_id = v_tree;
        v_expected := array['TREE_REFERENCE_DUPLICATED'];
      when 'ambiguous_identity' then
        update public.documents set document_id = v_b where document_id = v_doc;
        update public.tree_orders set children = array[v_b] where tree_order_id = v_tree;
        v_expected := array['TREE_REFERENCE_DUPLICATED'];
      when 'null_reference' then
        update public.tree_orders set children = array[null::uuid] where tree_order_id = v_tree;
        v_expected := array['TREE_REFERENCE_NOT_FOUND'];
      when 'multidimensional_order' then
        update public.tree_orders set children = array[array[v_b, v_doc]] where tree_order_id = v_tree;
        v_expected := array['TREE_REFERENCE_NOT_FOUND'];
      when 'control_reference' then
        update public.tree_orders set children = array[v_a, v_control]
        where project_id = v_project and parent_folder_id is null;
        v_expected := array['TREE_REFERENCE_NOT_FOUND'];
      when 'control_wrong_uuid' then
        update public.documents set document_id = gen_random_uuid() where document_id = v_control;
        v_expected := array['INVALID_CONTROL_DOCUMENT', 'STORAGE_NAME_INVALID'];
      when 'control_invalid_metadata' then
        update public.documents set name = 'not a control' where document_id = v_control;
        v_expected := array['INVALID_CONTROL_DOCUMENT'];
      when 'invalid_storage_name' then
        update public.documents set name = 'CON.txt' where document_id = v_doc;
        v_expected := array['STORAGE_NAME_INVALID'];
      when 'sibling_collision' then
        update public.documents set name = 'CHILD' where document_id = v_doc;
        v_expected := array['PATH_CONFLICT'];
      when 'valid_v2_contract' then
        update private.sync_contract_allowlist set enabled = true
        where canonical_contract_sha256 = 'abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c';
      else null;
    end case;
    -- Every malformed fixture still satisfies the real FK/CHECK constraints.
    set constraints all immediate;
    set constraints all deferred;
    set local role authenticated;
    v_result := public.begin_project_sync_migration(v_project, v_device,
      case when v_case = 'valid_v2_contract'
           then 'abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c' else v_digest end);
    reset role;
    if v_result->>'status' is distinct from 'migrating' then
      raise exception 'begin failed for %: %', v_case, v_result;
    end if;
    v_before := pg_temp.migration_fingerprint(v_project);
    select to_jsonb(m) into v_audit_before from public.project_sync_migrations m where project_id = v_project;

    set local role authenticated;
    v_validation := public.validate_project_sync_migration(v_project);
    reset role;
    select coalesce(array_agg(issue->>'code' order by issue->>'code'), '{}'::text[]) into v_codes
    from jsonb_array_elements(v_validation->'issues') issue;
    if v_codes is distinct from v_expected
       or (v_validation->>'valid')::boolean is distinct from (cardinality(v_expected) = 0)
       or v_validation->>'project_id' is distinct from v_project::text
       or exists (select 1 from jsonb_array_elements(v_validation->'issues') issue where (issue->>'count')::bigint <= 0) then
      raise exception 'validation mismatch for %: %, expected %', v_case, v_validation, v_expected;
    end if;
    if pg_temp.migration_fingerprint(v_project) is distinct from v_before
       or (select to_jsonb(m) from public.project_sync_migrations m where project_id = v_project) is distinct from v_audit_before then
      raise exception 'standalone validation mutated project %', v_case;
    end if;

    set local role authenticated;
    v_result := public.complete_project_sync_migration(v_project, v_device, 1);
    reset role;
    if v_result->'validation' is distinct from v_validation then
      raise exception 'complete did not use current validation for %: %', v_case, v_result;
    end if;
    if cardinality(v_expected) > 0 then
      if v_result->>'status' is distinct from 'validation_failed'
         or pg_temp.migration_fingerprint(v_project) is distinct from v_before
         or (select to_jsonb(m) - 'validation_result' from public.project_sync_migrations m where project_id = v_project)
            is distinct from (v_audit_before - 'validation_result')
         or (select validation_result from public.project_sync_migrations where project_id = v_project)
            is distinct from v_validation then
        raise exception 'invalid migration changed mode/data/audit for %: %', v_case, v_result;
      end if;
    else
      if v_result->>'status' is distinct from 'id_based'
         or not exists (select 1 from public.project_sync_settings where project_id = v_project
                        and project_sync_mode = 'ID_BASED' and migration_epoch = 1)
         or not exists (select 1 from public.project_sync_migrations where project_id = v_project
                        and completed_at is not null and target_mode = 'ID_BASED'
                        and completed_by_user_id = v_owner and validation_result = v_validation)
         or exists (select 1 from public.documents d where project_id = v_project
                    and relative_path like '__antigravity__/%' and storage_name_key is not null) then
        raise exception 'valid migration failed for %: %', v_case, v_result;
      end if;
      -- The only entity mutation permitted on success is populating name keys.
      if (select jsonb_agg(to_jsonb(d) - 'storage_name_key' order by document_id)
          from public.documents d where project_id = v_project)
         is distinct from (select jsonb_agg(d - 'storage_name_key' order by d->>'document_id')
                           from jsonb_array_elements(nullif(v_before->'documents', 'null'::jsonb)) d)
         or (select jsonb_agg(to_jsonb(f) - 'storage_name_key' order by folder_id)
             from public.folders f where project_id = v_project)
            is distinct from (select jsonb_agg(f - 'storage_name_key' order by f->>'folder_id')
                              from jsonb_array_elements(nullif(v_before->'folders', 'null'::jsonb)) f)
         or (select jsonb_agg(to_jsonb(t) order by tree_order_id)
             from public.tree_orders t where project_id = v_project)
            is distinct from nullif(v_before->'tree_orders', 'null'::jsonb)
         or exists (select 1 from public.folders where project_id = v_project and not is_deleted
                    and storage_name_key is distinct from private.storage_name_v1(name))
         or exists (select 1 from public.documents where project_id = v_project and not is_deleted
                    and name is not null and storage_name_key is distinct from private.storage_name_v1(name)) then
        raise exception 'successful migration changed document body/identity for %', v_case;
      end if;
    end if;
    raise notice 'migration_validation_case_passed: %', v_case;
  end loop;
end;
$cases$;

do $security$
declare
  v_project uuid := gen_random_uuid();
  v_owner constant uuid := '98000000-0000-4000-8000-000000000001';
  v_device constant uuid := '68000000-0000-4000-8000-000000000001';
  v_call text;
  v_result jsonb;
  v_before jsonb;
begin
  if has_function_privilege('anon', 'public.validate_project_sync_migration(uuid)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.validate_project_sync_migration(uuid)', 'EXECUTE')
     or exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
                lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                where n.nspname = 'public' and p.proname = 'validate_project_sync_migration'
                  and a.grantee = 0 and a.privilege_type = 'EXECUTE')
     or not exists (select 1 from pg_proc where oid = 'public.validate_project_sync_migration(uuid)'::regprocedure
                    and prosecdef and proconfig @> array['search_path=""']) then
    raise exception 'validator privilege/search_path changed';
  end if;
  insert into public.projects(project_id, owner_id, name) values (v_project, v_owner, 'auth fixture');
  insert into public.project_members(project_id, user_id, role) values
    (v_project, v_owner, 'owner'),
    (v_project, '98000000-0000-4000-8000-000000000002', 'viewer'),
    (v_project, '98000000-0000-4000-8000-000000000003', 'editor');
  set local role authenticated;
  perform public.begin_project_sync_migration(v_project, v_device,
    '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670');
  reset role;
  v_before := pg_temp.migration_fingerprint(v_project);
  v_call := format('select public.validate_project_sync_migration(%L)', v_project);
  perform set_config('request.jwt.claim.sub', '', true);
  perform pg_temp.expect_migration_error(v_call, 'AUTH_REQUIRED');
  perform set_config('request.jwt.claim.sub', '98000000-0000-4000-8000-000000000004', true);
  perform pg_temp.expect_migration_error(v_call, 'FORBIDDEN');
  perform set_config('request.jwt.claim.sub', '98000000-0000-4000-8000-000000000002', true);
  perform pg_temp.expect_migration_error(v_call, 'FORBIDDEN');
  perform set_config('request.jwt.claim.sub', '98000000-0000-4000-8000-000000000003', true);
  set local role authenticated;
  v_result := public.validate_project_sync_migration(v_project);
  reset role;
  if v_result->>'valid' is distinct from 'true' then raise exception 'editor validation failed'; end if;
  perform pg_temp.expect_migration_error(format('select public.complete_project_sync_migration(%L,%L,1)', v_project, v_device), 'FORBIDDEN');
  perform set_config('request.jwt.claim.sub', v_owner::text, true);
  perform pg_temp.expect_migration_error(format('select public.complete_project_sync_migration(%L,%L,2)', v_project, v_device), 'STALE_MIGRATION_EPOCH');
  perform pg_temp.expect_migration_error(format('select public.complete_project_sync_migration(%L,%L,1)', v_project, gen_random_uuid()), 'MIGRATION_LOCKED');
  update private.sync_contract_allowlist set enabled = false
  where canonical_contract_sha256 = '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670';
  perform pg_temp.expect_migration_error(v_call, 'CONTRACT_NOT_ALLOWED');
  if pg_temp.migration_fingerprint(v_project) is distinct from v_before then
    raise exception 'rejected caller changed migration';
  end if;
  raise notice 'migration_validation_security_passed';
end;
$security$;

rollback;
select 'project_sync_migration_validation_sql_passed: 25 cases + security' as result;
