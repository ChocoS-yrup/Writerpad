\set ON_ERROR_STOP on
\pset pager off

-- Exact, non-secret Stage 7 staging revalidation harness.
-- The caller must perform the separately approved guarded allowlist activation
-- before invoking this file. This file never mutates the allowlist.

\if :{?test_run_id}
\else
  \echo 'missing required psql variable: test_run_id'
  \quit 2
\endif
\if :{?server_project_id}
\else
  \echo 'missing required psql variable: server_project_id'
  \quit 2
\endif
\if :{?client_build_id}
\else
  \echo 'missing required psql variable: client_build_id'
  \quit 2
\endif
\if :{?owner_user_id}
\else
  \echo 'missing required psql variable: owner_user_id'
  \quit 2
\endif
\if :{?unauthorized_user_id}
\else
  \echo 'missing required psql variable: unauthorized_user_id'
  \quit 2
\endif
\if :{?existing_fixture_project_id}
\else
  \echo 'missing required psql variable: existing_fixture_project_id'
  \quit 2
\endif
\if :{?expected_existing_fixture_fingerprint}
\else
  \echo 'missing required psql variable: expected_existing_fixture_fingerprint'
  \quit 2
\endif

\set contract_version '0.3.0'
\set contract_git_commit '2705fcbda0be440a9d82a5e1919f2885c6166727'
\set contract_sha256 'abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c'
\set client_capabilities_json '["folders_authoritative","tree_order_ids","tombstones","immutable_batch_contract_metadata","operation_attempt_history","operation_state_events","storage_name_v2","document_commit_v1"]'
\set normal_content 'Stage 7 normal document'

set plpgsql.variable_conflict = error;

-- Validate all externally supplied identifiers before any write.
select
  :'test_run_id'::uuid as validated_test_run_id,
  :'server_project_id'::uuid as validated_server_project_id,
  :'owner_user_id'::uuid as validated_owner_user_id,
  :'unauthorized_user_id'::uuid as validated_unauthorized_user_id,
  :'existing_fixture_project_id'::uuid as validated_existing_fixture_project_id;

select
  pg_catalog.gen_random_uuid()::text as writer_device_id,
  pg_catalog.gen_random_uuid()::text as gate_bad_batch_id,
  pg_catalog.gen_random_uuid()::text as gate_bad_operation_id,
  pg_catalog.gen_random_uuid()::text as gate_bad_entity_id,
  pg_catalog.gen_random_uuid()::text as gate_capability_batch_id,
  pg_catalog.gen_random_uuid()::text as gate_capability_operation_id,
  pg_catalog.gen_random_uuid()::text as gate_capability_entity_id,
  pg_catalog.gen_random_uuid()::text as gate_valid_batch_id,
  pg_catalog.gen_random_uuid()::text as gate_valid_operation_id,
  pg_catalog.gen_random_uuid()::text as gate_valid_entity_id,
  pg_catalog.gen_random_uuid()::text as normal_batch_id,
  pg_catalog.gen_random_uuid()::text as normal_operation_id,
  pg_catalog.gen_random_uuid()::text as normal_document_id,
  pg_catalog.gen_random_uuid()::text as empty_batch_id,
  pg_catalog.gen_random_uuid()::text as empty_operation_id,
  pg_catalog.gen_random_uuid()::text as empty_document_id,
  pg_catalog.gen_random_uuid()::text as atomic_batch_id,
  pg_catalog.gen_random_uuid()::text as atomic_folder_operation_id,
  pg_catalog.gen_random_uuid()::text as atomic_folder_id,
  pg_catalog.gen_random_uuid()::text as atomic_tree_operation_id,
  pg_catalog.gen_random_uuid()::text as atomic_tree_id,
  pg_catalog.gen_random_uuid()::text as rollback_batch_id,
  pg_catalog.gen_random_uuid()::text as rollback_folder_operation_id,
  pg_catalog.gen_random_uuid()::text as rollback_folder_id,
  pg_catalog.gen_random_uuid()::text as rollback_tree_operation_id,
  pg_catalog.gen_random_uuid()::text as rollback_missing_child_id,
  pg_catalog.gen_random_uuid()::text as auth_atomic_batch_id,
  pg_catalog.gen_random_uuid()::text as auth_document_batch_id,
  pg_catalog.gen_random_uuid()::text as forbidden_atomic_batch_id,
  pg_catalog.gen_random_uuid()::text as forbidden_document_batch_id
\gset h_

-- Read-only preconditions. The exact five-entry migration-ledger check remains
-- an external preflight because local PostgreSQL applies these files directly.
select (
  pg_catalog.current_setting('server_version_num')::integer between 170000 and 179999
  and (select count(*) from private.sync_contract_allowlist as a
       where a.contract_version = :'contract_version'
         and a.canonical_contract_sha256 = :'contract_sha256'
         and a.contract_git_commit = :'contract_git_commit'
         and a.enabled
         and a.revoked_at is null) = 1
  and (select count(*) from private.sync_contract_allowlist as a where a.enabled) = 1
  and (select count(*) from auth.users as u
       where u.id in (:'owner_user_id'::uuid, :'unauthorized_user_id'::uuid)) = 2
  and exists (
    select 1 from public.projects as p
    where p.project_id = :'existing_fixture_project_id'::uuid
  )
  and not exists (
    select 1 from public.projects as p
    where p.project_id = :'server_project_id'::uuid
  )
  and not exists (
    select 1 from public.project_sync_migrations as m
    where m.completed_at is null
  )
) as passed
\gset preflight_
\if :preflight_passed
\else
  \echo 'Stage 7 harness preflight mismatch'
  \quit 1
\endif

select (
  pg_catalog.to_regprocedure('public.atomic_structure_commit(jsonb)') is not null
  and pg_catalog.to_regprocedure('public.document_commit(jsonb)') is not null
  and pg_catalog.to_regprocedure('public.atomic_structure_commit_legacy(jsonb)') is not null
  and pg_catalog.to_regprocedure('public.document_commit_legacy(jsonb)') is not null
  and pg_catalog.has_function_privilege(
    'anon', 'public.atomic_structure_commit(jsonb)', 'execute'
  )
  and pg_catalog.has_function_privilege(
    'authenticated', 'public.atomic_structure_commit(jsonb)', 'execute'
  )
  and pg_catalog.has_function_privilege(
    'anon', 'public.document_commit(jsonb)', 'execute'
  )
  and pg_catalog.has_function_privilege(
    'authenticated', 'public.document_commit(jsonb)', 'execute'
  )
  and not pg_catalog.has_function_privilege(
    'public', 'public.atomic_structure_commit(jsonb)', 'execute'
  )
  and not pg_catalog.has_function_privilege(
    'public', 'public.document_commit(jsonb)', 'execute'
  )
  and not pg_catalog.has_function_privilege(
    'anon', 'public.atomic_structure_commit_legacy(jsonb)', 'execute'
  )
  and not pg_catalog.has_function_privilege(
    'authenticated', 'public.atomic_structure_commit_legacy(jsonb)', 'execute'
  )
  and not pg_catalog.has_function_privilege(
    'anon', 'public.document_commit_legacy(jsonb)', 'execute'
  )
  and not pg_catalog.has_function_privilege(
    'authenticated', 'public.document_commit_legacy(jsonb)', 'execute'
  )
) as passed
\gset acl_
\if :acl_passed
\else
  \echo 'corrective wrapper ACL mismatch'
  \quit 1
\endif

\ir stage7_revalidation_fingerprint_helpers.sql
select
  pg_temp.writerpad_state_without_project(
    :'server_project_id'::uuid
  ) as existing_state_before,
  pg_temp.writerpad_project_snapshot(
    :'existing_fixture_project_id'::uuid
  ) as existing_fixture_before
\gset fingerprint_

select (
  :'expected_existing_fixture_fingerprint' = 'capture'
  or :'expected_existing_fixture_fingerprint' = :'fingerprint_existing_fixture_before'
) as passed
\gset expected_fixture_
\if :expected_fixture_passed
\else
  \echo 'existing fixture fingerprint differs from the approved preflight'
  \quit 1
\endif

-- Create only the caller-selected new synthetic project through the public API.
begin;
select pg_catalog.set_config(
  'request.jwt.claim.sub', :'owner_user_id', true
);
set local role authenticated;
select public.ensure_project(
  :'server_project_id'::uuid,
  'Stage 7 storage-name-v2 revalidation ' || :'test_run_id'
) as response
\gset ensure_project_
commit;

select (
  :'ensure_project_response'::jsonb->>'project_id' = :'server_project_id'
  and exists (
    select 1
    from public.projects as p
    where p.project_id = :'server_project_id'::uuid
      and p.owner_id = :'owner_user_id'::uuid
      and p.name = 'Stage 7 storage-name-v2 revalidation ' || :'test_run_id'
  )
  and exists (
    select 1
    from public.project_members as pm
    where pm.project_id = :'server_project_id'::uuid
      and pm.user_id = :'owner_user_id'::uuid
      and pm.role = 'owner'
  )
  and not exists (
    select 1 from public.project_sync_settings as s
    where s.project_id = :'server_project_id'::uuid
  )
  and not exists (
    select 1 from public.project_sync_migrations as m
    where m.project_id = :'server_project_id'::uuid
  )
) as passed
\gset project_setup_
\if :project_setup_passed
\else
  \echo 'synthetic project setup mismatch'
  \quit 1
\endif

-- Direct storage-name conformance, including supplementary adjacency and
-- post-NFKC separator rejection.
with vectors(vector_id, input_name, expected_valid, expected_normalized,
             expected_utf8_hex, expected_error_code) as (
  values
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
),
actual as (
  select
    v.vector_id,
    v.expected_valid,
    v.expected_normalized,
    v.expected_utf8_hex,
    v.expected_error_code,
    private.storage_name_v2_result(v.input_name) as result
  from vectors as v
),
comparison as (
  select
    a.vector_id,
    (
      (a.result->>'valid')::boolean is not distinct from a.expected_valid
      and (
        (a.expected_valid
         and a.result->>'normalized' is not distinct from a.expected_normalized
         and a.result->>'utf8_hex' is not distinct from a.expected_utf8_hex)
        or
        (not a.expected_valid
         and a.result->>'error_code' is not distinct from a.expected_error_code)
      )
    ) as passed
  from actual as a
)
select
  pg_catalog.bool_and(c.passed) as passed,
  pg_catalog.count(*) as vector_count
from comparison as c
\gset storage_vectors_
\if :storage_vectors_passed
\else
  \echo 'SN-001..SN-029 mismatch'
  \quit 1
\endif

select (
  :'storage_vectors_vector_count'::integer = 29
  and (private.storage_name_v1_result(U&'\E000')->>'valid')::boolean
) as passed
\gset storage_v1_before_
\if :storage_v1_before_passed
\else
  \echo 'storage-name-v1 compatibility mismatch before validated routing'
  \quit 1
\endif

-- Contract rejection and transaction-local routing are read-only.
begin;
set transaction read only;
select pg_catalog.set_config(
  'request.jwt.claim.sub', :'owner_user_id', true
);

with payload as (
  select pg_catalog.jsonb_build_object('name', 'bad-digest') as value
),
intent as (
  select pg_catalog.jsonb_build_object(
    'sequence', 1,
    'operation_id', :'h_gate_bad_operation_id',
    'batch_id', :'h_gate_bad_batch_id',
    'entity_kind', 'folder',
    'entity_id', :'h_gate_bad_entity_id',
    'intent_kind', 'create',
    'base_revision', 0,
    'payload_sha256', private.jsonb_rfc8785_sha256(p.value),
    'payload', p.value
  ) as value
  from payload as p
),
intents as (
  select pg_catalog.jsonb_build_array(i.value) as value from intent as i
),
batch as (
  select pg_catalog.jsonb_build_object(
    'batch_id', :'h_gate_bad_batch_id',
    'writer_device_id', :'h_writer_device_id',
    'client_build_id', :'client_build_id',
    'sync_protocol_version', 3,
    'contract_version', :'contract_version',
    'canonical_contract_sha256', pg_catalog.repeat('0', 64),
    'client_capabilities', :'client_capabilities_json'::jsonb,
    'batch_payload_sha256', private.jsonb_rfc8785_sha256(i.value)
  ) as value
  from intents as i
),
request as (
  select pg_catalog.jsonb_build_object(
    'kind', 'atomic_structure_commit_request',
    'project_id', :'server_project_id',
    'project_sync_mode', 'LEGACY',
    'migration_epoch', 0,
    'batch', b.value,
    'ordered_intents', i.value
  ) as value
  from batch as b cross join intents as i
)
select public.atomic_structure_commit(r.value) as response
from request as r
\gset bad_digest_

select (
  :'bad_digest_response'::jsonb->'error'->>'code' = 'CONTRACT_DIGEST_MISMATCH'
  and not (:'bad_digest_response'::jsonb->>'applied')::boolean
  and not exists (
    select 1 from public.sync_batches as b
    where b.batch_id = :'h_gate_bad_batch_id'::uuid
  )
) as passed
\gset bad_digest_assert_
\if :bad_digest_assert_passed
\else
  \echo 'bad digest rejection mismatch: ' :bad_digest_response
  \quit 1
\endif

with payload as (
  select pg_catalog.jsonb_build_object('name', 'capability-mismatch') as value
),
intent as (
  select pg_catalog.jsonb_build_object(
    'sequence', 1,
    'operation_id', :'h_gate_capability_operation_id',
    'batch_id', :'h_gate_capability_batch_id',
    'entity_kind', 'folder',
    'entity_id', :'h_gate_capability_entity_id',
    'intent_kind', 'create',
    'base_revision', 0,
    'payload_sha256', private.jsonb_rfc8785_sha256(p.value),
    'payload', p.value
  ) as value
  from payload as p
),
intents as (
  select pg_catalog.jsonb_build_array(i.value) as value from intent as i
),
batch as (
  select pg_catalog.jsonb_build_object(
    'batch_id', :'h_gate_capability_batch_id',
    'writer_device_id', :'h_writer_device_id',
    'client_build_id', :'client_build_id',
    'sync_protocol_version', 3,
    'contract_version', :'contract_version',
    'canonical_contract_sha256', :'contract_sha256',
    'client_capabilities',
      '["folders_authoritative","tree_order_ids","tombstones","immutable_batch_contract_metadata","operation_attempt_history","operation_state_events","document_commit_v1"]'::jsonb,
    'batch_payload_sha256', private.jsonb_rfc8785_sha256(i.value)
  ) as value
  from intents as i
),
request as (
  select pg_catalog.jsonb_build_object(
    'kind', 'atomic_structure_commit_request',
    'project_id', :'server_project_id',
    'project_sync_mode', 'LEGACY',
    'migration_epoch', 0,
    'batch', b.value,
    'ordered_intents', i.value
  ) as value
  from batch as b cross join intents as i
)
select public.atomic_structure_commit(r.value) as response
from request as r
\gset capability_

select (
  :'capability_response'::jsonb->'error'->>'code' = 'CAPABILITY_MISMATCH'
  and not (:'capability_response'::jsonb->>'applied')::boolean
  and not exists (
    select 1 from public.sync_batches as b
    where b.batch_id = :'h_gate_capability_batch_id'::uuid
  )
) as passed
\gset capability_assert_
\if :capability_assert_passed
\else
  \echo 'capability mismatch rejection failed: ' :capability_response
  \quit 1
\endif

with payload as (
  select pg_catalog.jsonb_build_object('name', 'validated-route') as value
),
intent as (
  select pg_catalog.jsonb_build_object(
    'sequence', 1,
    'operation_id', :'h_gate_valid_operation_id',
    'batch_id', :'h_gate_valid_batch_id',
    'entity_kind', 'folder',
    'entity_id', :'h_gate_valid_entity_id',
    'intent_kind', 'create',
    'base_revision', 0,
    'payload_sha256', private.jsonb_rfc8785_sha256(p.value),
    'payload', p.value
  ) as value
  from payload as p
),
intents as (
  select pg_catalog.jsonb_build_array(i.value) as value from intent as i
),
batch as (
  select pg_catalog.jsonb_build_object(
    'batch_id', :'h_gate_valid_batch_id',
    'writer_device_id', :'h_writer_device_id',
    'client_build_id', :'client_build_id',
    'sync_protocol_version', 3,
    'contract_version', :'contract_version',
    'canonical_contract_sha256', :'contract_sha256',
    'client_capabilities', :'client_capabilities_json'::jsonb,
    'batch_payload_sha256', private.jsonb_rfc8785_sha256(i.value)
  ) as value
  from intents as i
)
select private.validate_contract_request(
  :'owner_user_id'::uuid,
  :'server_project_id'::uuid,
  'LEGACY',
  0,
  b.value,
  i.value
)
from batch as b cross join intents as i;

select (
  pg_catalog.current_setting('writerpad.contract_sha256', true) = :'contract_sha256'
  and not (private.storage_name_v1_result(U&'\E000')->>'valid')::boolean
  and private.storage_name_v1_result(U&'\E000')->>'error_code'
      = 'STORAGE_NAME_UNSUPPORTED_SCALAR'
) as passed
\gset validated_route_
\if :validated_route_passed
\else
  \echo 'validated 0.3.0 request did not select storage-name-v2'
  \quit 1
\endif
commit;
-- A real second connection proves the contract pin is transaction-local.
\connect -reuse-previous=on
\pset pager off
\set ON_ERROR_STOP on
set plpgsql.variable_conflict = error;
select (
  pg_catalog.current_setting('writerpad.contract_sha256', true)
    is distinct from :'contract_sha256'
  and (private.storage_name_v1_result(U&'\E000')->>'valid')::boolean
  and not exists (
    select 1 from public.sync_batches as b
    where b.batch_id in (
      :'h_gate_bad_batch_id'::uuid,
      :'h_gate_capability_batch_id'::uuid,
      :'h_gate_valid_batch_id'::uuid
    )
  )
) as passed
\gset route_reset_
\if :route_reset_passed
\else
  \echo 'transaction-local route leaked or contract gates persisted data'
  \quit 1
\endif

-- All persistent functional cases share one transaction. Any harness
-- assertion failure closes the psql connection and rolls this transaction back.
begin;
select pg_catalog.set_config(
  'request.jwt.claim.sub', :'owner_user_id', true
);

with payload as (
  select pg_catalog.jsonb_build_object(
    'parent_folder_id', null,
    'name', 'Normal.md',
    'content', :'normal_content',
    'content_sha256', private.content_sha256(:'normal_content'),
    'content_byte_count', pg_catalog.octet_length(:'normal_content'),
    'is_deleted', false,
    'structure_revision', 1
  ) as value
),
intent as (
  select pg_catalog.jsonb_build_object(
    'sequence', 1,
    'operation_id', :'h_normal_operation_id',
    'batch_id', :'h_normal_batch_id',
    'entity_kind', 'document',
    'document_id', :'h_normal_document_id',
    'intent_kind', 'create',
    'base_revision', 0,
    'payload_sha256', private.jsonb_rfc8785_sha256(p.value),
    'payload', p.value
  ) as value
  from payload as p
),
intents as (
  select pg_catalog.jsonb_build_array(i.value) as value from intent as i
),
batch as (
  select pg_catalog.jsonb_build_object(
    'batch_id', :'h_normal_batch_id',
    'writer_device_id', :'h_writer_device_id',
    'client_build_id', :'client_build_id',
    'sync_protocol_version', 3,
    'contract_version', :'contract_version',
    'canonical_contract_sha256', :'contract_sha256',
    'client_capabilities', :'client_capabilities_json'::jsonb,
    'batch_payload_sha256', private.jsonb_rfc8785_sha256(i.value)
  ) as value
  from intents as i
),
request as (
  select pg_catalog.jsonb_build_object(
    'kind', 'document_commit_request',
    'project_id', :'server_project_id',
    'project_sync_mode', 'LEGACY',
    'migration_epoch', 0,
    'batch', b.value,
    'ordered_intents', i.value
  ) as value
  from batch as b cross join intents as i
)
select public.document_commit(r.value) as response
from request as r
\gset normal_

select (
  :'normal_response'::jsonb->>'kind' = 'document_commit_success'
  and :'normal_response'::jsonb->>'status' = 'committed'
  and (:'normal_response'::jsonb->>'applied')::boolean
  and pg_catalog.jsonb_array_length(
    :'normal_response'::jsonb->'results'
  ) = 1
  and exists (
    select 1
    from public.documents as d
    where d.document_id = :'h_normal_document_id'::uuid
      and d.project_id = :'server_project_id'::uuid
      and d.name = 'Normal.md'
      and d.content = :'normal_content'
      and d.revision = 1
      and d.structure_revision = 1
      and not d.is_deleted
  )
) as passed
\gset normal_assert_
\if :normal_assert_passed
\else
  \echo 'normal document_commit mismatch: ' :normal_response
  \quit 1
\endif

with payload as (
  select pg_catalog.jsonb_build_object(
    'parent_folder_id', null,
    'name', 'Empty.md',
    'content', '',
    'content_sha256', private.content_sha256(''),
    'content_byte_count', 0,
    'is_deleted', false,
    'structure_revision', 1
  ) as value
),
intent as (
  select pg_catalog.jsonb_build_object(
    'sequence', 1,
    'operation_id', :'h_empty_operation_id',
    'batch_id', :'h_empty_batch_id',
    'entity_kind', 'document',
    'document_id', :'h_empty_document_id',
    'intent_kind', 'create',
    'base_revision', 0,
    'payload_sha256', private.jsonb_rfc8785_sha256(p.value),
    'payload', p.value
  ) as value
  from payload as p
),
intents as (
  select pg_catalog.jsonb_build_array(i.value) as value from intent as i
),
batch as (
  select pg_catalog.jsonb_build_object(
    'batch_id', :'h_empty_batch_id',
    'writer_device_id', :'h_writer_device_id',
    'client_build_id', :'client_build_id',
    'sync_protocol_version', 3,
    'contract_version', :'contract_version',
    'canonical_contract_sha256', :'contract_sha256',
    'client_capabilities', :'client_capabilities_json'::jsonb,
    'batch_payload_sha256', private.jsonb_rfc8785_sha256(i.value)
  ) as value
  from intents as i
),
request as (
  select pg_catalog.jsonb_build_object(
    'kind', 'document_commit_request',
    'project_id', :'server_project_id',
    'project_sync_mode', 'LEGACY',
    'migration_epoch', 0,
    'batch', b.value,
    'ordered_intents', i.value
  ) as value
  from batch as b cross join intents as i
)
select public.document_commit(r.value) as response
from request as r
\gset empty_

select (
  :'empty_response'::jsonb->>'kind' = 'document_commit_success'
  and :'empty_response'::jsonb->>'status' = 'committed'
  and (:'empty_response'::jsonb->>'applied')::boolean
  and :'empty_response'::jsonb->'results'->0->>'content_sha256'
    = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
  and (:'empty_response'::jsonb->'results'->0->>'content_byte_count')::integer = 0
  and exists (
    select 1
    from public.documents as d
    where d.document_id = :'h_empty_document_id'::uuid
      and d.project_id = :'server_project_id'::uuid
      and d.name = 'Empty.md'
      and d.content = ''
      and d.revision = 1
      and not d.is_deleted
  )
) as passed
\gset empty_assert_
\if :empty_assert_passed
\else
  \echo 'empty document_commit mismatch: ' :empty_response
  \quit 1
\endif

with folder_payload as (
  select pg_catalog.jsonb_build_object('name', 'Atomic Folder') as value
),
folder_intent as (
  select pg_catalog.jsonb_build_object(
    'sequence', 1,
    'operation_id', :'h_atomic_folder_operation_id',
    'batch_id', :'h_atomic_batch_id',
    'entity_kind', 'folder',
    'entity_id', :'h_atomic_folder_id',
    'intent_kind', 'create',
    'base_revision', 0,
    'payload_sha256', private.jsonb_rfc8785_sha256(p.value),
    'payload', p.value
  ) as value
  from folder_payload as p
),
tree_payload as (
  select pg_catalog.jsonb_build_object(
    'children', pg_catalog.jsonb_build_array(:'h_atomic_folder_id')
  ) as value
),
tree_intent as (
  select pg_catalog.jsonb_build_object(
    'sequence', 2,
    'operation_id', :'h_atomic_tree_operation_id',
    'batch_id', :'h_atomic_batch_id',
    'entity_kind', 'tree_order',
    'entity_id', :'h_atomic_tree_id',
    'intent_kind', 'reorder',
    'base_revision', 0,
    'payload_sha256', private.jsonb_rfc8785_sha256(p.value),
    'payload', p.value
  ) as value
  from tree_payload as p
),
intents as (
  select pg_catalog.jsonb_build_array(f.value, t.value) as value
  from folder_intent as f cross join tree_intent as t
),
batch as (
  select pg_catalog.jsonb_build_object(
    'batch_id', :'h_atomic_batch_id',
    'writer_device_id', :'h_writer_device_id',
    'client_build_id', :'client_build_id',
    'sync_protocol_version', 3,
    'contract_version', :'contract_version',
    'canonical_contract_sha256', :'contract_sha256',
    'client_capabilities', :'client_capabilities_json'::jsonb,
    'batch_payload_sha256', private.jsonb_rfc8785_sha256(i.value)
  ) as value
  from intents as i
),
request as (
  select pg_catalog.jsonb_build_object(
    'kind', 'atomic_structure_commit_request',
    'project_id', :'server_project_id',
    'project_sync_mode', 'LEGACY',
    'migration_epoch', 0,
    'batch', b.value,
    'ordered_intents', i.value
  ) as value
  from batch as b cross join intents as i
)
select public.atomic_structure_commit(r.value) as response
from request as r
\gset atomic_

select (
  :'atomic_response'::jsonb->>'kind' = 'atomic_structure_commit_success'
  and :'atomic_response'::jsonb->>'status' = 'committed'
  and (:'atomic_response'::jsonb->>'applied')::boolean
  and pg_catalog.jsonb_array_length(
    :'atomic_response'::jsonb->'results'
  ) = 2
  and exists (
    select 1
    from public.folders as f
    where f.folder_id = :'h_atomic_folder_id'::uuid
      and f.project_id = :'server_project_id'::uuid
      and f.name = 'Atomic Folder'
      and f.revision = 1
  )
  and exists (
    select 1
    from public.tree_orders as t
    where t.tree_order_id = :'h_atomic_tree_id'::uuid
      and t.project_id = :'server_project_id'::uuid
      and t.children = array[:'h_atomic_folder_id'::uuid]
      and t.revision = 1
  )
) as passed
\gset atomic_assert_
\if :atomic_assert_passed
\else
  \echo 'atomic multi-intent commit mismatch: ' :atomic_response
  \quit 1
\endif

-- Rebuild the byte-identical request for exact replay.
with folder_payload as (
  select pg_catalog.jsonb_build_object('name', 'Atomic Folder') as value
),
folder_intent as (
  select pg_catalog.jsonb_build_object(
    'sequence', 1,
    'operation_id', :'h_atomic_folder_operation_id',
    'batch_id', :'h_atomic_batch_id',
    'entity_kind', 'folder',
    'entity_id', :'h_atomic_folder_id',
    'intent_kind', 'create',
    'base_revision', 0,
    'payload_sha256', private.jsonb_rfc8785_sha256(p.value),
    'payload', p.value
  ) as value
  from folder_payload as p
),
tree_payload as (
  select pg_catalog.jsonb_build_object(
    'children', pg_catalog.jsonb_build_array(:'h_atomic_folder_id')
  ) as value
),
tree_intent as (
  select pg_catalog.jsonb_build_object(
    'sequence', 2,
    'operation_id', :'h_atomic_tree_operation_id',
    'batch_id', :'h_atomic_batch_id',
    'entity_kind', 'tree_order',
    'entity_id', :'h_atomic_tree_id',
    'intent_kind', 'reorder',
    'base_revision', 0,
    'payload_sha256', private.jsonb_rfc8785_sha256(p.value),
    'payload', p.value
  ) as value
  from tree_payload as p
),
intents as (
  select pg_catalog.jsonb_build_array(f.value, t.value) as value
  from folder_intent as f cross join tree_intent as t
),
batch as (
  select pg_catalog.jsonb_build_object(
    'batch_id', :'h_atomic_batch_id',
    'writer_device_id', :'h_writer_device_id',
    'client_build_id', :'client_build_id',
    'sync_protocol_version', 3,
    'contract_version', :'contract_version',
    'canonical_contract_sha256', :'contract_sha256',
    'client_capabilities', :'client_capabilities_json'::jsonb,
    'batch_payload_sha256', private.jsonb_rfc8785_sha256(i.value)
  ) as value
  from intents as i
),
request as (
  select pg_catalog.jsonb_build_object(
    'kind', 'atomic_structure_commit_request',
    'project_id', :'server_project_id',
    'project_sync_mode', 'LEGACY',
    'migration_epoch', 0,
    'batch', b.value,
    'ordered_intents', i.value
  ) as value
  from batch as b cross join intents as i
)
select public.atomic_structure_commit(r.value) as response
from request as r
\gset replay_

select (
  :'replay_response'::jsonb->>'status' = 'replayed'
  and (:'replay_response'::jsonb->>'applied')::boolean
  and (select f.revision from public.folders as f
       where f.folder_id = :'h_atomic_folder_id'::uuid) = 1
  and (select t.revision from public.tree_orders as t
       where t.tree_order_id = :'h_atomic_tree_id'::uuid) = 1
) as passed
\gset replay_assert_
\if :replay_assert_passed
\else
  \echo 'exact replay mismatch: ' :replay_response
  \quit 1
\endif

-- Same batch ID with different ordered-intent bytes.
with payload as (
  select pg_catalog.jsonb_build_object('name', 'Different Payload') as value
),
intent as (
  select pg_catalog.jsonb_build_object(
    'sequence', 1,
    'operation_id', :'h_atomic_folder_operation_id',
    'batch_id', :'h_atomic_batch_id',
    'entity_kind', 'folder',
    'entity_id', :'h_atomic_folder_id',
    'intent_kind', 'create',
    'base_revision', 0,
    'payload_sha256', private.jsonb_rfc8785_sha256(p.value),
    'payload', p.value
  ) as value
  from payload as p
),
intents as (
  select pg_catalog.jsonb_build_array(i.value) as value from intent as i
),
batch as (
  select pg_catalog.jsonb_build_object(
    'batch_id', :'h_atomic_batch_id',
    'writer_device_id', :'h_writer_device_id',
    'client_build_id', :'client_build_id',
    'sync_protocol_version', 3,
    'contract_version', :'contract_version',
    'canonical_contract_sha256', :'contract_sha256',
    'client_capabilities', :'client_capabilities_json'::jsonb,
    'batch_payload_sha256', private.jsonb_rfc8785_sha256(i.value)
  ) as value
  from intents as i
),
request as (
  select pg_catalog.jsonb_build_object(
    'kind', 'atomic_structure_commit_request',
    'project_id', :'server_project_id',
    'project_sync_mode', 'LEGACY',
    'migration_epoch', 0,
    'batch', b.value,
    'ordered_intents', i.value
  ) as value
  from batch as b cross join intents as i
)
select public.atomic_structure_commit(r.value) as response
from request as r
\gset reused_

select (
  :'reused_response'::jsonb->'error'->>'code' = 'BATCH_ID_REUSED'
  and not (:'reused_response'::jsonb->>'applied')::boolean
  and (select f.name from public.folders as f
       where f.folder_id = :'h_atomic_folder_id'::uuid) = 'Atomic Folder'
) as passed
\gset reused_assert_
\if :reused_assert_passed
\else
  \echo 'BATCH_ID_REUSED mismatch: ' :reused_response
  \quit 1
\endif

with folder_payload as (
  select pg_catalog.jsonb_build_object('name', 'Should Roll Back') as value
),
folder_intent as (
  select pg_catalog.jsonb_build_object(
    'sequence', 1,
    'operation_id', :'h_rollback_folder_operation_id',
    'batch_id', :'h_rollback_batch_id',
    'entity_kind', 'folder',
    'entity_id', :'h_rollback_folder_id',
    'intent_kind', 'create',
    'base_revision', 0,
    'payload_sha256', private.jsonb_rfc8785_sha256(p.value),
    'payload', p.value
  ) as value
  from folder_payload as p
),
tree_payload as (
  select pg_catalog.jsonb_build_object(
    'children', pg_catalog.jsonb_build_array(:'h_rollback_missing_child_id')
  ) as value
),
tree_intent as (
  select pg_catalog.jsonb_build_object(
    'sequence', 2,
    'operation_id', :'h_rollback_tree_operation_id',
    'batch_id', :'h_rollback_batch_id',
    'entity_kind', 'tree_order',
    'entity_id', :'h_atomic_tree_id',
    'intent_kind', 'reorder',
    'base_revision', 1,
    'payload_sha256', private.jsonb_rfc8785_sha256(p.value),
    'payload', p.value
  ) as value
  from tree_payload as p
),
intents as (
  select pg_catalog.jsonb_build_array(f.value, t.value) as value
  from folder_intent as f cross join tree_intent as t
),
batch as (
  select pg_catalog.jsonb_build_object(
    'batch_id', :'h_rollback_batch_id',
    'writer_device_id', :'h_writer_device_id',
    'client_build_id', :'client_build_id',
    'sync_protocol_version', 3,
    'contract_version', :'contract_version',
    'canonical_contract_sha256', :'contract_sha256',
    'client_capabilities', :'client_capabilities_json'::jsonb,
    'batch_payload_sha256', private.jsonb_rfc8785_sha256(i.value)
  ) as value
  from intents as i
),
request as (
  select pg_catalog.jsonb_build_object(
    'kind', 'atomic_structure_commit_request',
    'project_id', :'server_project_id',
    'project_sync_mode', 'LEGACY',
    'migration_epoch', 0,
    'batch', b.value,
    'ordered_intents', i.value
  ) as value
  from batch as b cross join intents as i
)
select public.atomic_structure_commit(r.value) as response
from request as r
\gset rollback_

select (
  :'rollback_response'::jsonb->'error'->>'code' = 'TREE_REFERENCE_NOT_FOUND'
  and not (:'rollback_response'::jsonb->>'applied')::boolean
  and (:'rollback_response'::jsonb->'error'->>'failed_sequence')::integer = 2
  and not exists (
    select 1 from public.folders as f
    where f.folder_id = :'h_rollback_folder_id'::uuid
  )
  and exists (
    select 1
    from public.sync_batch_results as br
    where br.batch_id = :'h_rollback_batch_id'::uuid
      and not br.applied
  )
) as passed
\gset rollback_assert_
\if :rollback_assert_passed
\else
  \echo 'atomic rollback mismatch: ' :rollback_response
  \quit 1
\endif

select (
  not exists (
    select 1 from public.project_sync_settings as s
    where s.project_id = :'server_project_id'::uuid
  )
  and not exists (
    select 1 from public.project_sync_migrations as m
    where m.project_id = :'server_project_id'::uuid
  )
  and (select f.name from public.folders as f
       where f.folder_id = :'h_atomic_folder_id'::uuid) = 'Atomic Folder'
  and (select d.name from public.documents as d
       where d.document_id = :'h_normal_document_id'::uuid) = 'Normal.md'
  and (select d.name from public.documents as d
       where d.document_id = :'h_empty_document_id'::uuid) = 'Empty.md'
) as passed
\gset functional_invariants_
\if :functional_invariants_passed
\else
  \echo 'project mode, migration, or name invariant mismatch'
  \quit 1
\endif
commit;

select
  (select d.revision from public.documents as d
   where d.document_id = :'h_normal_document_id'::uuid) as document_revision,
  (select count(*) from public.document_versions as dv
   where dv.document_id = :'h_normal_document_id'::uuid) as version_count,
  (select count(*) from public.sync_batches as b
   where b.project_id = :'server_project_id'::uuid) as batch_count,
  (select count(*) from public.sync_operations as o
   where o.project_id = :'server_project_id'::uuid) as operation_count
\gset response_loss_before_

-- A second real connection replays the normal document request after the
-- original response could have been lost.
\connect -reuse-previous=on
\pset pager off
\set ON_ERROR_STOP on
set plpgsql.variable_conflict = error;
select pg_catalog.set_config(
  'request.jwt.claim.sub', :'owner_user_id', false
);

with payload as (
  select pg_catalog.jsonb_build_object(
    'parent_folder_id', null,
    'name', 'Normal.md',
    'content', :'normal_content',
    'content_sha256', private.content_sha256(:'normal_content'),
    'content_byte_count', pg_catalog.octet_length(:'normal_content'),
    'is_deleted', false,
    'structure_revision', 1
  ) as value
),
intent as (
  select pg_catalog.jsonb_build_object(
    'sequence', 1,
    'operation_id', :'h_normal_operation_id',
    'batch_id', :'h_normal_batch_id',
    'entity_kind', 'document',
    'document_id', :'h_normal_document_id',
    'intent_kind', 'create',
    'base_revision', 0,
    'payload_sha256', private.jsonb_rfc8785_sha256(p.value),
    'payload', p.value
  ) as value
  from payload as p
),
intents as (
  select pg_catalog.jsonb_build_array(i.value) as value from intent as i
),
batch as (
  select pg_catalog.jsonb_build_object(
    'batch_id', :'h_normal_batch_id',
    'writer_device_id', :'h_writer_device_id',
    'client_build_id', :'client_build_id',
    'sync_protocol_version', 3,
    'contract_version', :'contract_version',
    'canonical_contract_sha256', :'contract_sha256',
    'client_capabilities', :'client_capabilities_json'::jsonb,
    'batch_payload_sha256', private.jsonb_rfc8785_sha256(i.value)
  ) as value
  from intents as i
),
request as (
  select pg_catalog.jsonb_build_object(
    'kind', 'document_commit_request',
    'project_id', :'server_project_id',
    'project_sync_mode', 'LEGACY',
    'migration_epoch', 0,
    'batch', b.value,
    'ordered_intents', i.value
  ) as value
  from batch as b cross join intents as i
)
select public.document_commit(r.value) as response
from request as r
\gset response_loss_

select (
  :'response_loss_response'::jsonb->>'status' = 'replayed'
  and (:'response_loss_response'::jsonb->>'applied')::boolean
  and (select d.revision from public.documents as d
       where d.document_id = :'h_normal_document_id'::uuid)
      = :'response_loss_before_document_revision'::bigint
  and (select count(*) from public.document_versions as dv
       where dv.document_id = :'h_normal_document_id'::uuid)
      = :'response_loss_before_version_count'::bigint
  and (select count(*) from public.sync_batches as b
       where b.project_id = :'server_project_id'::uuid)
      = :'response_loss_before_batch_count'::bigint
  and (select count(*) from public.sync_operations as o
       where o.project_id = :'server_project_id'::uuid)
      = :'response_loss_before_operation_count'::bigint
) as passed
\gset response_loss_assert_
\if :response_loss_assert_passed
\else
  \echo 'separate-connection response-loss replay mismatch: ' :response_loss_response
  \quit 1
\endif

select
  (select count(*) from public.sync_batches as b
   where b.project_id = :'server_project_id'::uuid) as batches,
  (select count(*) from public.sync_batch_results as br
   join public.sync_batches as b on b.batch_id = br.batch_id
   where b.project_id = :'server_project_id'::uuid) as batch_results,
  (select count(*) from public.sync_operations as o
   where o.project_id = :'server_project_id'::uuid) as operations,
  (select count(*) from public.sync_operation_attempts as a
   join public.sync_operations as o on o.operation_id = a.operation_id
   where o.project_id = :'server_project_id'::uuid) as attempts,
  (select count(*) from public.sync_operation_events as e
   join public.sync_operations as o on o.operation_id = e.operation_id
   where o.project_id = :'server_project_id'::uuid) as events,
  (select count(*) from public.folders as f
   where f.project_id = :'server_project_id'::uuid) as folders,
  (select count(*) from public.documents as d
   where d.project_id = :'server_project_id'::uuid) as documents,
  (select count(*) from public.document_versions as dv
   where dv.project_id = :'server_project_id'::uuid) as document_versions,
  (select count(*) from public.tree_orders as t
   where t.project_id = :'server_project_id'::uuid) as tree_orders
\gset auth_before_

-- Canonical AUTH_REQUIRED envelopes through the anon role.
select pg_catalog.set_config('request.jwt.claim.sub', '', false);
set role anon;
select public.atomic_structure_commit(pg_catalog.jsonb_build_object(
  'kind', 'atomic_structure_commit_request',
  'project_id', :'server_project_id',
  'project_sync_mode', 'LEGACY',
  'migration_epoch', 0,
  'batch', pg_catalog.jsonb_build_object(
    'batch_id', :'h_auth_atomic_batch_id',
    'batch_payload_sha256', pg_catalog.repeat('a', 64)
  )
)) as response
\gset auth_atomic_
reset role;

select pg_catalog.set_config('request.jwt.claim.sub', '', false);
set role anon;
select public.document_commit(pg_catalog.jsonb_build_object(
  'kind', 'document_commit_request',
  'project_id', :'server_project_id',
  'project_sync_mode', 'LEGACY',
  'migration_epoch', 0,
  'batch', pg_catalog.jsonb_build_object(
    'batch_id', :'h_auth_document_batch_id',
    'batch_payload_sha256', pg_catalog.repeat('b', 64)
  )
)) as response
\gset auth_document_
reset role;

-- Canonical FORBIDDEN envelopes through the authenticated role.
select pg_catalog.set_config(
  'request.jwt.claim.sub', :'unauthorized_user_id', false
);
set role authenticated;
select public.atomic_structure_commit(pg_catalog.jsonb_build_object(
  'kind', 'atomic_structure_commit_request',
  'project_id', :'server_project_id',
  'project_sync_mode', 'LEGACY',
  'migration_epoch', 0,
  'batch', pg_catalog.jsonb_build_object(
    'batch_id', :'h_forbidden_atomic_batch_id',
    'batch_payload_sha256', pg_catalog.repeat('c', 64)
  )
)) as response
\gset forbidden_atomic_
reset role;

select pg_catalog.set_config(
  'request.jwt.claim.sub', :'unauthorized_user_id', false
);
set role authenticated;
select public.document_commit(pg_catalog.jsonb_build_object(
  'kind', 'document_commit_request',
  'project_id', :'server_project_id',
  'project_sync_mode', 'LEGACY',
  'migration_epoch', 0,
  'batch', pg_catalog.jsonb_build_object(
    'batch_id', :'h_forbidden_document_batch_id',
    'writer_device_id', :'h_writer_device_id',
    'client_build_id', :'client_build_id',
    'sync_protocol_version', 3,
    'contract_version', :'contract_version',
    'canonical_contract_sha256', :'contract_sha256',
    'client_capabilities', :'client_capabilities_json'::jsonb,
    'batch_payload_sha256', pg_catalog.repeat('d', 64)
  ),
  'ordered_intents', pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object(
      'sequence', 1,
      'operation_id', pg_catalog.gen_random_uuid(),
      'batch_id', :'h_forbidden_document_batch_id',
      'entity_kind', 'document',
      'document_id', pg_catalog.gen_random_uuid(),
      'intent_kind', 'create',
      'base_revision', 0,
      'payload_sha256', pg_catalog.repeat('e', 64),
      'payload', pg_catalog.jsonb_build_object(
        'parent_folder_id', null,
        'name', 'forbidden.md',
        'content', '',
        'content_sha256',
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        'content_byte_count', 0,
        'is_deleted', false,
        'structure_revision', 1
      )
    )
  )
)) as response
\gset forbidden_document_
reset role;

select (
  :'auth_atomic_response'::jsonb->>'kind' = 'atomic_structure_commit_failure'
  and :'auth_atomic_response'::jsonb->>'status' = 'rejected'
  and not (:'auth_atomic_response'::jsonb->>'applied')::boolean
  and :'auth_atomic_response'::jsonb->'error'->>'code' = 'AUTH_REQUIRED'
  and :'auth_atomic_response'::jsonb->'error'->>'message' <> ''
  and :'auth_atomic_response'::jsonb->'error'->>'failed_sequence' is null
  and :'auth_atomic_response'::jsonb->'results' = '[]'::jsonb
  and :'auth_document_response'::jsonb->>'kind' = 'document_commit_failure'
  and :'auth_document_response'::jsonb->>'status' = 'rejected'
  and not (:'auth_document_response'::jsonb->>'applied')::boolean
  and :'auth_document_response'::jsonb->'error'->>'code' = 'AUTH_REQUIRED'
  and :'auth_document_response'::jsonb->'error'->>'message' <> ''
  and :'auth_document_response'::jsonb->'error'->>'failed_sequence' is null
  and :'auth_document_response'::jsonb->'results' = '[]'::jsonb
  and :'forbidden_atomic_response'::jsonb->>'kind'
      = 'atomic_structure_commit_failure'
  and :'forbidden_atomic_response'::jsonb->>'status' = 'rejected'
  and not (:'forbidden_atomic_response'::jsonb->>'applied')::boolean
  and :'forbidden_atomic_response'::jsonb->'error'->>'code' = 'FORBIDDEN'
  and :'forbidden_atomic_response'::jsonb->'error'->>'message' <> ''
  and :'forbidden_atomic_response'::jsonb->'error'->>'failed_sequence' is null
  and :'forbidden_atomic_response'::jsonb->'results' = '[]'::jsonb
  and :'forbidden_document_response'::jsonb->>'kind'
      = 'document_commit_failure'
  and :'forbidden_document_response'::jsonb->>'status' = 'rejected'
  and not (:'forbidden_document_response'::jsonb->>'applied')::boolean
  and :'forbidden_document_response'::jsonb->'error'->>'code' = 'FORBIDDEN'
  and :'forbidden_document_response'::jsonb->'error'->>'message' <> ''
  and :'forbidden_document_response'::jsonb->'error'->>'failed_sequence' is null
  and :'forbidden_document_response'::jsonb->'results' = '[]'::jsonb
) as passed
\gset auth_envelopes_
\if :auth_envelopes_passed
\else
  \echo 'canonical AUTH_REQUIRED or FORBIDDEN envelope mismatch'
  \quit 1
\endif

select (
  (select count(*) from public.sync_batches as b
   where b.project_id = :'server_project_id'::uuid)
    = :'auth_before_batches'::bigint
  and (select count(*) from public.sync_batch_results as br
       join public.sync_batches as b on b.batch_id = br.batch_id
       where b.project_id = :'server_project_id'::uuid)
    = :'auth_before_batch_results'::bigint
  and (select count(*) from public.sync_operations as o
       where o.project_id = :'server_project_id'::uuid)
    = :'auth_before_operations'::bigint
  and (select count(*) from public.sync_operation_attempts as a
       join public.sync_operations as o on o.operation_id = a.operation_id
       where o.project_id = :'server_project_id'::uuid)
    = :'auth_before_attempts'::bigint
  and (select count(*) from public.sync_operation_events as e
       join public.sync_operations as o on o.operation_id = e.operation_id
       where o.project_id = :'server_project_id'::uuid)
    = :'auth_before_events'::bigint
  and (select count(*) from public.folders as f
       where f.project_id = :'server_project_id'::uuid)
    = :'auth_before_folders'::bigint
  and (select count(*) from public.documents as d
       where d.project_id = :'server_project_id'::uuid)
    = :'auth_before_documents'::bigint
  and (select count(*) from public.document_versions as dv
       where dv.project_id = :'server_project_id'::uuid)
    = :'auth_before_document_versions'::bigint
  and (select count(*) from public.tree_orders as t
       where t.project_id = :'server_project_id'::uuid)
    = :'auth_before_tree_orders'::bigint
) as passed
\gset unauthorized_writes_
\if :unauthorized_writes_passed
\else
  \echo 'authorization rejection changed persistent state'
  \quit 1
\endif

-- Recreate only session-local helpers after the connection switch.
\ir stage7_revalidation_fingerprint_helpers.sql
select
  pg_temp.writerpad_state_without_project(
    :'server_project_id'::uuid
  ) as existing_state_after,
  pg_temp.writerpad_project_snapshot(
    :'existing_fixture_project_id'::uuid
  ) as existing_fixture_after,
  pg_temp.writerpad_project_snapshot(
    :'server_project_id'::uuid
  ) as new_fixture_fingerprint
\gset final_fingerprint_

select (
  :'final_fingerprint_existing_state_after'
    = :'fingerprint_existing_state_before'
  and :'final_fingerprint_existing_fixture_after'
    = :'fingerprint_existing_fixture_before'
  and (
    :'expected_existing_fixture_fingerprint' = 'capture'
    or :'final_fingerprint_existing_fixture_after'
      = :'expected_existing_fixture_fingerprint'
  )
  and (select count(*) from private.sync_contract_allowlist as a
       where a.contract_version = :'contract_version'
         and a.canonical_contract_sha256 = :'contract_sha256'
         and a.contract_git_commit = :'contract_git_commit'
         and a.enabled
         and a.revoked_at is null) = 1
  and (select count(*) from private.sync_contract_allowlist as a
       where a.enabled) = 1
  and not exists (
    select 1 from public.project_sync_settings as s
    where s.project_id = :'server_project_id'::uuid
  )
  and not exists (
    select 1 from public.project_sync_migrations as m
    where m.project_id = :'server_project_id'::uuid
  )
  and not exists (
    select 1 from public.project_sync_migrations as m
    where m.completed_at is null
  )
  and (select count(*) from public.projects as p
       where p.project_id = :'server_project_id'::uuid) = 1
  and (select count(*) from public.project_members as pm
       where pm.project_id = :'server_project_id'::uuid) = 1
  and (select count(*) from public.folders as f
       where f.project_id = :'server_project_id'::uuid) = 1
  and (select count(*) from public.documents as d
       where d.project_id = :'server_project_id'::uuid) = 2
  and (select count(*) from public.document_versions as dv
       where dv.project_id = :'server_project_id'::uuid) = 2
  and (select count(*) from public.tree_orders as t
       where t.project_id = :'server_project_id'::uuid) = 1
  and (select count(*) from public.sync_batches as b
       where b.project_id = :'server_project_id'::uuid) = 4
  and (select count(*) from public.sync_batch_results as br
       join public.sync_batches as b on b.batch_id = br.batch_id
       where b.project_id = :'server_project_id'::uuid) = 4
  and (select count(*) from public.sync_operations as o
       where o.project_id = :'server_project_id'::uuid) = 6
  and (select count(*) from public.sync_operation_attempts as a
       join public.sync_operations as o on o.operation_id = a.operation_id
       where o.project_id = :'server_project_id'::uuid) = 6
  and (select count(*) from public.sync_operation_events as e
       join public.sync_operations as o on o.operation_id = e.operation_id
       where o.project_id = :'server_project_id'::uuid) = 18
  and not exists (
    select 1 from public.folders as f
    where f.folder_id = :'h_rollback_folder_id'::uuid
  )
  and (select p.name from public.projects as p
       where p.project_id = :'server_project_id'::uuid)
      = 'Stage 7 storage-name-v2 revalidation ' || :'test_run_id'
  and (select f.name from public.folders as f
       where f.folder_id = :'h_atomic_folder_id'::uuid) = 'Atomic Folder'
  and (select d.name from public.documents as d
       where d.document_id = :'h_normal_document_id'::uuid) = 'Normal.md'
  and (select d.name from public.documents as d
       where d.document_id = :'h_empty_document_id'::uuid) = 'Empty.md'
) as passed
\gset final_audit_
\if :final_audit_passed
\else
  \echo 'final Stage 7 harness audit mismatch'
  \quit 1
\endif

select pg_catalog.jsonb_build_object(
  'result', 'PASS',
  'test_run_id', :'test_run_id',
  'server_project_id', :'server_project_id',
  'client_build_id', :'client_build_id',
  'contract_version', :'contract_version',
  'canonical_contract_sha256', :'contract_sha256',
  'existing_state_fingerprint', :'final_fingerprint_existing_state_after',
  'existing_fixture_fingerprint', :'final_fingerprint_existing_fixture_after',
  'new_fixture_fingerprint', :'final_fingerprint_new_fixture_fingerprint',
  'project_sync_mode', 'LEGACY',
  'migration_epoch', 0,
  'active_contract_sha256', null,
  'automatic_project_migrations', 0,
  'name_rewrites', 0,
  'unauthorized_persistent_writes', 0,
  'new_fixture_rows', pg_catalog.jsonb_build_object(
    'projects', 1,
    'project_members', 1,
    'folders', 1,
    'documents', 2,
    'document_versions', 2,
    'tree_orders', 1,
    'sync_batches', 4,
    'sync_batch_results', 4,
    'sync_operations', 6,
    'sync_operation_attempts', 6,
    'sync_operation_events', 18,
    'project_sync_settings', 0,
    'project_sync_migrations', 0
  )
) as stage7_staging_revalidation;
