\set ON_ERROR_STOP on

-- These are role-boundary tests. They intentionally use a project that does
-- not exist, so the authenticated caller is a non-member and no application
-- row can be mutated by the test.
create temporary table rpc_auth_before as
select
  (select count(*) from public.sync_batches) as batches,
  (select count(*) from public.sync_batch_results) as batch_results,
  (select count(*) from public.sync_operations) as operations,
  (select count(*) from public.sync_operation_attempts) as attempts,
  (select count(*) from public.sync_operation_events) as events,
  (select count(*) from public.folders) as folders,
  (select count(*) from public.documents) as documents,
  (select count(*) from public.document_versions) as document_versions,
  (select count(*) from public.tree_orders) as tree_orders,
  (select count(*) from public.project_sync_settings) as project_settings,
  (select count(*) from public.project_sync_migrations) as project_migrations;

select set_config('request.jwt.claim.sub', '', false);
set role anon;
select public.atomic_structure_commit($request$
{
  "kind":"atomic_structure_commit_request",
  "project_id":"00000000-0000-4000-8000-000000009901",
  "project_sync_mode":"ID_BASED",
  "migration_epoch":1,
  "batch":{
    "batch_id":"10000000-0000-4000-8000-000000009901",
    "batch_payload_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
}
$request$::jsonb) as response \gset unauth_atomic_
reset role;

select set_config('request.jwt.claim.sub', '', false);
set role anon;
select public.document_commit($request$
{
  "kind":"document_commit_request",
  "project_id":"00000000-0000-4000-8000-000000009901",
  "project_sync_mode":"ID_BASED",
  "migration_epoch":1,
  "batch":{
    "batch_id":"10000000-0000-4000-8000-000000009902",
    "batch_payload_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  }
}
$request$::jsonb) as response \gset unauth_document_
reset role;

select set_config('request.jwt.claim.sub', '90000000-0000-4000-8000-000000009902', false);
set role authenticated;
select public.atomic_structure_commit($request$
{
  "kind":"atomic_structure_commit_request",
  "project_id":"00000000-0000-4000-8000-000000009901",
  "project_sync_mode":"ID_BASED",
  "migration_epoch":1,
  "batch":{
    "batch_id":"10000000-0000-4000-8000-000000009903",
    "batch_payload_sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  }
}
$request$::jsonb) as response \gset forbidden_atomic_
reset role;

select set_config('request.jwt.claim.sub', '90000000-0000-4000-8000-000000009902', false);
set role authenticated;
select public.document_commit($request$
{
  "kind":"document_commit_request",
  "project_id":"00000000-0000-4000-8000-000000009901",
  "project_sync_mode":"ID_BASED",
  "migration_epoch":1,
  "batch":{
    "batch_id":"10000000-0000-4000-8000-000000009904",
    "writer_device_id":"60000000-0000-4000-8000-000000009904",
    "client_build_id":"auth-envelope-test",
    "sync_protocol_version":3,
    "contract_version":"0.3.0",
    "canonical_contract_sha256":"abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c",
    "client_capabilities":["document_commit_v1"],
    "batch_payload_sha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  },
  "ordered_intents":[{
    "sequence":1,
    "operation_id":"20000000-0000-4000-8000-000000009904",
    "batch_id":"10000000-0000-4000-8000-000000009904",
    "entity_kind":"document",
    "document_id":"30000000-0000-4000-8000-000000009904",
    "intent_kind":"create",
    "base_revision":0,
    "payload_sha256":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    "payload":{
      "parent_folder_id":null,
      "name":"auth-envelope-test.md",
      "content":"",
      "content_sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "content_byte_count":0,
      "is_deleted":false,
      "structure_revision":1
    }
  }]
}
$request$::jsonb) as response \gset forbidden_document_
reset role;

do $assert_envelopes$
declare
  v_response jsonb;
  v_before record;
begin
  v_response := :'unauth_atomic_response'::jsonb;
  if v_response->>'kind' <> 'atomic_structure_commit_failure'
     or v_response->>'batch_id' <> '10000000-0000-4000-8000-000000009901'
     or v_response->>'batch_payload_sha256' <> repeat('a', 64)
     or v_response->>'status' <> 'rejected'
     or (v_response->>'applied')::boolean
     or v_response->'error'->>'code' <> 'AUTH_REQUIRED'
     or v_response->'error'->>'message' = ''
     or v_response->'error'->>'failed_sequence' is not null
     or v_response->'results' <> '[]'::jsonb then
    raise exception 'unauthenticated atomic envelope invalid: %', v_response;
  end if;

  v_response := :'unauth_document_response'::jsonb;
  if v_response->>'kind' <> 'document_commit_failure'
     or v_response->>'batch_id' <> '10000000-0000-4000-8000-000000009902'
     or v_response->>'batch_payload_sha256' <> repeat('b', 64)
     or v_response->>'status' <> 'rejected'
     or (v_response->>'applied')::boolean
     or v_response->'error'->>'code' <> 'AUTH_REQUIRED'
     or v_response->'error'->>'message' = ''
     or v_response->'error'->>'failed_sequence' is not null
     or v_response->'results' <> '[]'::jsonb then
    raise exception 'unauthenticated document envelope invalid: %', v_response;
  end if;

  v_response := :'forbidden_atomic_response'::jsonb;
  if v_response->>'kind' <> 'atomic_structure_commit_failure'
     or v_response->>'batch_id' <> '10000000-0000-4000-8000-000000009903'
     or v_response->>'batch_payload_sha256' <> repeat('c', 64)
     or v_response->>'status' <> 'rejected'
     or (v_response->>'applied')::boolean
     or v_response->'error'->>'code' <> 'FORBIDDEN'
     or v_response->'error'->>'message' = ''
     or v_response->'error'->>'failed_sequence' is not null
     or v_response->'results' <> '[]'::jsonb then
    raise exception 'forbidden atomic envelope invalid: %', v_response;
  end if;

  v_response := :'forbidden_document_response'::jsonb;
  if v_response->>'kind' <> 'document_commit_failure'
     or v_response->>'batch_id' <> '10000000-0000-4000-8000-000000009904'
     or v_response->>'batch_payload_sha256' <> repeat('d', 64)
     or v_response->>'status' <> 'rejected'
     or (v_response->>'applied')::boolean
     or v_response->'error'->>'code' <> 'FORBIDDEN'
     or v_response->'error'->>'message' = ''
     or v_response->'error'->>'failed_sequence' is not null
     or v_response->'results' <> '[]'::jsonb then
    raise exception 'forbidden document envelope invalid: %', v_response;
  end if;

  select * into v_before from rpc_auth_before;
  if (select count(*) from public.sync_batches) <> v_before.batches
     or (select count(*) from public.sync_batch_results) <> v_before.batch_results
     or (select count(*) from public.sync_operations) <> v_before.operations
     or (select count(*) from public.sync_operation_attempts) <> v_before.attempts
     or (select count(*) from public.sync_operation_events) <> v_before.events
     or (select count(*) from public.folders) <> v_before.folders
     or (select count(*) from public.documents) <> v_before.documents
     or (select count(*) from public.document_versions) <> v_before.document_versions
     or (select count(*) from public.tree_orders) <> v_before.tree_orders
     or (select count(*) from public.project_sync_settings) <> v_before.project_settings
     or (select count(*) from public.project_sync_migrations) <> v_before.project_migrations then
    raise exception 'authorization rejection changed persistent state';
  end if;
end;
$assert_envelopes$;

select 'rpc_auth_error_envelope: PASS' as result;
