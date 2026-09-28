\set ON_ERROR_STOP on
begin;
set local statement_timeout = '30s';

-- Isolated fixture: the direct document commit exercises the installed version
-- trigger. Its rows and the test user's identity are rolled back below.
do $contract03_document_boundary$
declare
  v_user uuid := '98000000-0000-4000-8000-000000000001';
  v_device uuid := '98000000-0000-4000-8000-000000000002';
  v_pin_02 text := '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670';
  v_pin_03 text := 'abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c';
  v_pin text;
  v_project uuid;
  v_document uuid;
  v_batch uuid;
  v_operation uuid;
  v_result jsonb;
  v_error text;
begin
  if pg_catalog.current_database() <> 'writerpad_stage7'
     or current_user <> 'postgres' then
    raise exception 'DOCUMENT_BOUNDARY_FIXTURE_SCOPE';
  end if;
  insert into auth.users(id) values (v_user);
  perform pg_catalog.set_config('request.jwt.claim.sub', v_user::text, true);

  for v_pin in select unnest(array[v_pin_02, v_pin_03]) loop
    v_project := pg_catalog.gen_random_uuid();
    v_document := pg_catalog.gen_random_uuid();
    v_batch := pg_catalog.gen_random_uuid();
    v_operation := pg_catalog.gen_random_uuid();
    insert into public.projects(project_id, owner_id, name)
      values (v_project, v_user, 'document boundary synthetic');
    insert into public.project_members(project_id, user_id, role)
      values (v_project, v_user, 'owner');
    insert into public.project_sync_settings(
      project_id, project_sync_mode, migration_epoch,
      contract_enforcement_started_at, active_contract_sha256
    ) values (v_project, 'ID_BASED', 1, pg_catalog.transaction_timestamp(), v_pin);
    insert into public.sync_batches(
      batch_id, project_id, writer_user_id, writer_device_id,
      client_build_id, sync_protocol_version, contract_version,
      canonical_contract_sha256, client_capabilities, batch_payload_sha256,
      project_sync_mode, migration_epoch, request_sha256
    ) select v_batch, v_project, v_user, v_device,
      'document-boundary-ci', 3, contract_version,
      v_pin, allowed_client_capabilities, repeat('a', 64),
      'ID_BASED', 1, repeat('b', 64)
      from private.sync_contract_allowlist
      where canonical_contract_sha256 = v_pin;
    insert into public.sync_operations(
      operation_id, project_id, provenance_kind, batch_id, sequence,
      entity_kind, entity_id, intent_kind, base_revision, payload_sha256,
      payload, created_by
    ) values (
      v_operation, v_project, 'CONTRACT_BATCH', v_batch, 1,
      'document', v_document, 'create', 0, repeat('c', 64),
      '{}'::jsonb, v_user
    );
    set local role authenticated;
    v_result := public.commit_document(
      v_document, v_project, 0, v_operation, v_device,
      'contract-boundary.txt', 'contract boundary', false, null
    );
    reset role;
    if v_result->>'status' <> 'committed'
       or not exists (
         select 1 from public.document_versions
         where project_id = v_project and operation_id = v_operation
       ) then
      raise exception 'ACTIVE_CONTRACT_DOCUMENT_REJECTED: %', v_pin;
    end if;
  end loop;

  -- A protocol-3 batch carrying the historical pin must not write a version
  -- into an ID_BASED project whose active pin is 0.3.
  v_project := pg_catalog.gen_random_uuid();
  v_document := pg_catalog.gen_random_uuid();
  v_batch := pg_catalog.gen_random_uuid();
  v_operation := pg_catalog.gen_random_uuid();
  insert into public.projects(project_id, owner_id, name)
    values (v_project, v_user, 'wrong-pin boundary synthetic');
  insert into public.project_members(project_id, user_id, role)
    values (v_project, v_user, 'owner');
  insert into public.project_sync_settings(
    project_id, project_sync_mode, migration_epoch,
    contract_enforcement_started_at, active_contract_sha256
  ) values (v_project, 'ID_BASED', 1, pg_catalog.transaction_timestamp(), v_pin_03);
  insert into public.sync_batches(
    batch_id, project_id, writer_user_id, writer_device_id,
    client_build_id, sync_protocol_version, contract_version,
    canonical_contract_sha256, client_capabilities, batch_payload_sha256,
    project_sync_mode, migration_epoch, request_sha256
  ) select v_batch, v_project, v_user, v_device,
    'document-boundary-ci', 3, contract_version,
    v_pin_02, allowed_client_capabilities, repeat('a', 64),
    'ID_BASED', 1, repeat('b', 64)
    from private.sync_contract_allowlist
    where canonical_contract_sha256 = v_pin_02;
  insert into public.sync_operations(
    operation_id, project_id, provenance_kind, batch_id, sequence,
    entity_kind, entity_id, intent_kind, base_revision, payload_sha256,
    payload, created_by
  ) values (
    v_operation, v_project, 'CONTRACT_BATCH', v_batch, 1,
    'document', v_document, 'create', 0, repeat('c', 64),
    '{}'::jsonb, v_user
  );
  begin
    set local role authenticated;
    perform public.commit_document(
      v_document, v_project, 0, v_operation, v_device,
      'contract-boundary.txt', 'must not commit', false, null
    );
    reset role;
    raise exception 'WRONG_CONTRACT_DOCUMENT_ACCEPTED';
  exception when sqlstate 'P0001' then
    get stacked diagnostics v_error = message_text;
    reset role;
    if v_error <> 'PROTOCOL_TOO_OLD' then
      raise exception 'WRONG_CONTRACT_ERROR: %', v_error;
    end if;
  end;
  if exists (select 1 from public.documents where project_id = v_project) then
    raise exception 'FAILED_DOCUMENT_WRITE_MUTATED_PROJECT';
  end if;
end;
$contract03_document_boundary$;

rollback;
