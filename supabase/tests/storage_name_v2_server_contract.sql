\set ON_ERROR_STOP on

-- The migration must be inert until an explicit rollout enables the new pin.
do $assert_disabled_pin$
declare
  v_entry private.sync_contract_allowlist%rowtype;
begin
  select * into strict v_entry
  from private.sync_contract_allowlist
  where canonical_contract_sha256 =
    'abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c';
  if v_entry.enabled
     or v_entry.contract_version <> '0.3.0'
     or v_entry.contract_git_commit <> '2705fcbda0be440a9d82a5e1919f2885c6166727'
     or v_entry.contract_content_commit <> '3843b05aa91461e1541f5ebaa14557dc3dc2b39c'
     or v_entry.canonical_contract_bytes <> 24777 then
    raise exception 'storage-name-v2 disabled pin mismatch';
  end if;
end;
$assert_disabled_pin$;

-- Direct conformance against all released SN-001..SN-029 vectors.
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
      ('SN-015', '', false, null, null, 'STORAGE_NAME_INVALID'),
      ('SN-016', U&'a\FF0Fb', false, null, null, 'STORAGE_NAME_INVALID'),
      ('SN-017', U&'\2105', false, null, null, 'STORAGE_NAME_INVALID'),
      ('SN-018', U&'\FE68', false, null, null, 'STORAGE_NAME_INVALID'),
      ('SN-019', U&'a\E000b', false, null, null, 'STORAGE_NAME_UNSUPPORTED_SCALAR'),
      ('SN-020', U&'\+0E0041', false, null, null, 'STORAGE_NAME_UNSUPPORTED_SCALAR'),
      ('SN-021', U&'\+0E0100', false, null, null, 'STORAGE_NAME_UNSUPPORTED_SCALAR'),
      ('SN-022', U&'\+01CCD6', false, null, null, 'STORAGE_NAME_UNASSIGNED'),
      ('SN-023', U&'\+010D50', false, null, null, 'STORAGE_NAME_UNASSIGNED'),
      ('SN-024', U&'\+013046\0301', false, null, null, 'STORAGE_NAME_INVALID'),
      ('SN-025', U&'\+013046\FF9E', false, null, null, 'STORAGE_NAME_INVALID'),
      ('SN-026', U&'\+013046a', true, U&'\+013046a', 'f093818661', null),
      ('SN-027', U&'\+01F642\FE0F', true, U&'\+01F642\FE0F', 'f09f9982efb88f', null),
      ('SN-028', U&'\AB70', true, U&'\13A0', 'e18ea0', null),
      ('SN-029', U&'\1C80', true, U&'\0432', 'd0b2', null)
    ) as vector(vector_id, input, valid, normalized, utf8_hex, error_code)
  loop
    v_actual := private.storage_name_v2_result(v_vector.input);
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

-- A migration install must not silently change direct historical v1 behavior.
do $assert_v1_compatibility$
begin
  if not (private.storage_name_v1_result(U&'\E000')->>'valid')::boolean then
    raise exception 'storage-name-v1 compatibility route changed without a validated v2 batch';
  end if;
end;
$assert_v1_compatibility$;

-- Exercise the real defensive post-NFKC baseline branch. Only this transaction
-- narrows the server baseline: U+AB70 passes input, frozen casefold produces
-- U+13A0, and the defensive recheck must reject it as unassigned. Rollback
-- restores the complete immutable table and trigger state.
begin;
alter table private.storage_name_v2_assigned_ranges
  disable trigger storage_name_v2_assigned_ranges_immutable;
delete from private.storage_name_v2_assigned_ranges;
insert into private.storage_name_v2_assigned_ranges(range_start, range_end)
values (43888, 43888);
do $assert_defensive_recheck$
declare
  v_actual jsonb;
begin
  v_actual := private.storage_name_v2_result(U&'\AB70');
  if (v_actual->>'valid')::boolean
     or v_actual->>'error_code' <> 'STORAGE_NAME_UNASSIGNED' then
    raise exception 'defensive post-NFKC baseline recheck missing: %', v_actual;
  end if;
end;
$assert_defensive_recheck$;
rollback;

-- A validated 0.3.0 batch selects v2 only within its transaction. This fixture
-- is local PostgreSQL test data; it does not promote or touch an external project.
select pg_catalog.set_config(
  'request.jwt.claim.sub',
  '91000000-0000-4000-8000-000000000001',
  false
);
insert into auth.users(id) values
  ('91000000-0000-4000-8000-000000000001');
insert into public.projects(project_id, owner_id, name) values
  ('01000000-0000-4000-8000-000000000301',
   '91000000-0000-4000-8000-000000000001',
   'storage-name-v2 local conformance');
insert into public.project_members(project_id, user_id, role) values
  ('01000000-0000-4000-8000-000000000301',
   '91000000-0000-4000-8000-000000000001',
   'owner');

update private.sync_contract_allowlist
set enabled = true
where canonical_contract_sha256 =
  'abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c';

do $assert_validated_route$
declare
  v_payload jsonb := '{"name":"v2"}'::jsonb;
  v_intent jsonb;
  v_intents jsonb;
  v_batch jsonb;
  v_actual jsonb;
begin
  v_intent := pg_catalog.jsonb_build_object(
    'sequence', 1,
    'operation_id', '21000000-0000-4000-8000-000000000301',
    'batch_id', '11000000-0000-4000-8000-000000000301',
    'entity_kind', 'folder',
    'entity_id', '31000000-0000-4000-8000-000000000301',
    'intent_kind', 'create',
    'base_revision', 0,
    'payload_sha256', private.jsonb_rfc8785_sha256(v_payload),
    'payload', v_payload
  );
  v_intents := pg_catalog.jsonb_build_array(v_intent);
  v_batch := pg_catalog.jsonb_build_object(
    'batch_id', '11000000-0000-4000-8000-000000000301',
    'writer_device_id', '61000000-0000-4000-8000-000000000301',
    'client_build_id', 'server-v2-conformance',
    'sync_protocol_version', 3,
    'contract_version', '0.3.0',
    'canonical_contract_sha256',
      'abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c',
    'client_capabilities', pg_catalog.jsonb_build_array(
      'folders_authoritative', 'tree_order_ids', 'tombstones',
      'immutable_batch_contract_metadata', 'operation_attempt_history',
      'operation_state_events', 'storage_name_v2', 'document_commit_v1'
    ),
    'batch_payload_sha256', private.jsonb_rfc8785_sha256(v_intents)
  );

  perform private.validate_contract_request(
    '91000000-0000-4000-8000-000000000001',
    '01000000-0000-4000-8000-000000000301',
    'LEGACY', 0, v_batch, v_intents
  );
  if pg_catalog.current_setting('writerpad.contract_sha256', true) <>
     'abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c' then
    raise exception 'validated batch did not set the transaction-local contract route';
  end if;
  v_actual := private.storage_name_v1_result(U&'\E000');
  if (v_actual->>'valid')::boolean
     or v_actual->>'error_code' <> 'STORAGE_NAME_UNSUPPORTED_SCALAR' then
    raise exception 'validated 0.3.0 request did not route to storage-name-v2: %', v_actual;
  end if;
end;
$assert_validated_route$;

select 'storage-name-v2 server conformance passed' as result;
