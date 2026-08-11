\set ON_ERROR_STOP on

-- These tests run as the database owner while auth.uid() is populated exactly
-- as PostgREST populates it for a signed-in user.
select pg_catalog.set_config(
  'request.jwt.claim.sub',
  '90000000-0000-4000-8000-000000000001',
  false
);

insert into auth.users(id) values
  ('90000000-0000-4000-8000-000000000001');

insert into public.projects(project_id, owner_id, name) values
  ('00000000-0000-4000-8000-000000000201',
   '90000000-0000-4000-8000-000000000001',
   'Stage 7 conformance');
insert into public.project_members(project_id, user_id, role) values
  ('00000000-0000-4000-8000-000000000201',
   '90000000-0000-4000-8000-000000000001',
   'owner');

-- Source migration installs the release disabled. Enabling it here represents
-- a staging-only rollout decision, not a production migration side effect.
update private.sync_contract_allowlist
set enabled = true
where canonical_contract_sha256 =
  'fae86b4e6385ee37fbeb99f9256194ec319b64bfda92974ce90a3eb70d2e7a46';

insert into public.project_sync_settings (
  project_id, project_sync_mode, migration_epoch,
  contract_enforcement_started_at, active_contract_sha256
) values (
  '00000000-0000-4000-8000-000000000201', 'ID_BASED', 1,
  pg_catalog.transaction_timestamp(),
  'fae86b4e6385ee37fbeb99f9256194ec319b64bfda92974ce90a3eb70d2e7a46'
);

insert into public.folders (
  folder_id, project_id, parent_folder_id, name, storage_name_key,
  revision, is_deleted, created_by, updated_by
) values (
  '30000000-0000-4000-8000-000000000201',
  '00000000-0000-4000-8000-000000000201',
  null, 'Before', private.storage_name_v1('Before'), 1, false,
  '90000000-0000-4000-8000-000000000001',
  '90000000-0000-4000-8000-000000000001'
);

insert into public.tree_orders (
  tree_order_id, project_id, parent_folder_id, children, revision,
  created_by, updated_by
) values (
  '50000000-0000-4000-8000-000000000201',
  '00000000-0000-4000-8000-000000000201',
  null,
  array['30000000-0000-4000-8000-000000000201'::uuid],
  1,
  '90000000-0000-4000-8000-000000000001',
  '90000000-0000-4000-8000-000000000001'
);

create temporary table stage7_results (
  case_id text primary key,
  response jsonb not null
);

insert into stage7_results(case_id, response)
select 'ASC-001', public.atomic_structure_commit($request$
{
  "kind": "atomic_structure_commit_request",
  "project_id": "00000000-0000-4000-8000-000000000201",
  "project_sync_mode": "ID_BASED",
  "migration_epoch": 1,
  "batch": {
    "batch_id": "10000000-0000-4000-8000-000000000201",
    "writer_device_id": "60000000-0000-4000-8000-000000000201",
    "client_build_id": "conformance-0.1.0",
    "sync_protocol_version": 3,
    "contract_version": "0.1.0",
    "canonical_contract_sha256": "fae86b4e6385ee37fbeb99f9256194ec319b64bfda92974ce90a3eb70d2e7a46",
    "client_capabilities": [
      "folders_authoritative",
      "tree_order_ids",
      "tombstones",
      "immutable_batch_contract_metadata",
      "operation_attempt_history",
      "operation_state_events",
      "storage_name_v1"
    ],
    "batch_payload_sha256": "0fd7de3e5329659757e0a391f3cfed43faac11a750ad13698301bfda7499e62c"
  },
  "ordered_intents": [
    {
      "sequence": 1,
      "operation_id": "20000000-0000-4000-8000-000000000201",
      "batch_id": "10000000-0000-4000-8000-000000000201",
      "entity_kind": "folder",
      "entity_id": "30000000-0000-4000-8000-000000000201",
      "intent_kind": "rename",
      "base_revision": 1,
      "payload_sha256": "3782e48c5bf35825af922f03357cb9357ee7d9a08df7175dec392a09cb912dc3",
      "payload": {"name": "Renamed"}
    },
    {
      "sequence": 2,
      "operation_id": "20000000-0000-4000-8000-000000000202",
      "batch_id": "10000000-0000-4000-8000-000000000201",
      "entity_kind": "tree_order",
      "entity_id": "50000000-0000-4000-8000-000000000201",
      "intent_kind": "reorder",
      "base_revision": 1,
      "payload_sha256": "abf3340eb74959cea7c406ffadfc9ecd6a4747cf1715718bf78a1e9fd4695fa7",
      "payload": {"children": ["30000000-0000-4000-8000-000000000201"]}
    }
  ]
}
$request$::jsonb);

do $assert_commit$
declare
  v_response jsonb;
begin
  select response into v_response from stage7_results where case_id = 'ASC-001';
  if v_response->>'kind' <> 'atomic_structure_commit_success'
     or v_response->>'status' <> 'committed'
     or not (v_response->>'applied')::boolean
     or pg_catalog.jsonb_array_length(v_response->'results') <> 2 then
    raise exception 'ASC-001 failed: %', v_response;
  end if;
  if (select name from public.folders
      where folder_id = '30000000-0000-4000-8000-000000000201') <> 'Renamed' then
    raise exception 'folder rename was not committed';
  end if;
end;
$assert_commit$;

insert into stage7_results(case_id, response)
select 'ASC-002', public.atomic_structure_commit($request$
{
  "kind":"atomic_structure_commit_request",
  "project_id":"00000000-0000-4000-8000-000000000201",
  "project_sync_mode":"ID_BASED",
  "migration_epoch":1,
  "batch":{
    "batch_id":"10000000-0000-4000-8000-000000000201",
    "writer_device_id":"60000000-0000-4000-8000-000000000201",
    "client_build_id":"conformance-0.1.0",
    "sync_protocol_version":3,
    "contract_version":"0.1.0",
    "canonical_contract_sha256":"fae86b4e6385ee37fbeb99f9256194ec319b64bfda92974ce90a3eb70d2e7a46",
    "client_capabilities":["folders_authoritative","tree_order_ids","tombstones","immutable_batch_contract_metadata","operation_attempt_history","operation_state_events","storage_name_v1"],
    "batch_payload_sha256":"0fd7de3e5329659757e0a391f3cfed43faac11a750ad13698301bfda7499e62c"
  },
  "ordered_intents":[
    {"sequence":1,"operation_id":"20000000-0000-4000-8000-000000000201","batch_id":"10000000-0000-4000-8000-000000000201","entity_kind":"folder","entity_id":"30000000-0000-4000-8000-000000000201","intent_kind":"rename","base_revision":1,"payload_sha256":"3782e48c5bf35825af922f03357cb9357ee7d9a08df7175dec392a09cb912dc3","payload":{"name":"Renamed"}},
    {"sequence":2,"operation_id":"20000000-0000-4000-8000-000000000202","batch_id":"10000000-0000-4000-8000-000000000201","entity_kind":"tree_order","entity_id":"50000000-0000-4000-8000-000000000201","intent_kind":"reorder","base_revision":1,"payload_sha256":"abf3340eb74959cea7c406ffadfc9ecd6a4747cf1715718bf78a1e9fd4695fa7","payload":{"children":["30000000-0000-4000-8000-000000000201"]}}
  ]
}
$request$::jsonb);

do $assert_replay$
declare v_response jsonb;
begin
  select response into v_response from stage7_results where case_id = 'ASC-002';
  if v_response->>'status' <> 'replayed'
     or pg_catalog.jsonb_array_length(v_response->'results') <> 2 then
    raise exception 'ASC-002 failed: %', v_response;
  end if;
  if (select revision from public.folders
      where folder_id = '30000000-0000-4000-8000-000000000201') <> 2 then
    raise exception 'replay changed folder revision';
  end if;
end;
$assert_replay$;

-- Same ID with changed bytes must never overwrite immutable metadata.
insert into stage7_results(case_id, response)
select 'ASC-004', public.atomic_structure_commit(
  pg_catalog.jsonb_set(
    $request$
    {
      "kind":"atomic_structure_commit_request",
      "project_id":"00000000-0000-4000-8000-000000000201",
      "project_sync_mode":"ID_BASED",
      "migration_epoch":1,
      "batch":{
        "batch_id":"10000000-0000-4000-8000-000000000201",
        "writer_device_id":"60000000-0000-4000-8000-000000000201",
        "client_build_id":"changed-build",
        "sync_protocol_version":3,
        "contract_version":"0.1.0",
        "canonical_contract_sha256":"fae86b4e6385ee37fbeb99f9256194ec319b64bfda92974ce90a3eb70d2e7a46",
        "client_capabilities":["folders_authoritative","tree_order_ids","tombstones","immutable_batch_contract_metadata","operation_attempt_history","operation_state_events","storage_name_v1"],
        "batch_payload_sha256":"9f29a4a93b6362d7fea10351f78717d3a9b98614837b3359ea89e2fbbd3351aa"
      },
      "ordered_intents":[
        {"sequence":1,"operation_id":"20000000-0000-4000-8000-000000000201","batch_id":"10000000-0000-4000-8000-000000000201","entity_kind":"folder","entity_id":"30000000-0000-4000-8000-000000000201","intent_kind":"rename","base_revision":1,"payload_sha256":"238c19be39dccc9be74d0122a5f3c6530d08bc814cdc991b8fcd9dd30bf68fa3","payload":{"name":"Different"}}
      ]
    }
    $request$::jsonb,
    '{batch,batch_payload_sha256}',
    '"9f29a4a93b6362d7fea10351f78717d3a9b98614837b3359ea89e2fbbd3351aa"'::jsonb
  )
);

do $assert_reuse$
declare v_response jsonb;
begin
  select response into v_response from stage7_results where case_id = 'ASC-004';
  if v_response->'error'->>'code' <> 'BATCH_ID_REUSED'
     or (v_response->>'applied')::boolean then
    raise exception 'ASC-004 failed: %', v_response;
  end if;
end;
$assert_reuse$;

-- Cancellation is append-only and deterministic.
insert into public.sync_batches (
  batch_id, project_id, writer_user_id, writer_device_id, client_build_id,
  sync_protocol_version, contract_version, canonical_contract_sha256,
  client_capabilities, batch_payload_sha256, project_sync_mode,
  migration_epoch, request_sha256
) values (
  '10000000-0000-4000-8000-000000000211',
  '00000000-0000-4000-8000-000000000201',
  '90000000-0000-4000-8000-000000000001',
  '60000000-0000-4000-8000-000000000201', 'test', 3, '0.1.0',
  'fae86b4e6385ee37fbeb99f9256194ec319b64bfda92974ce90a3eb70d2e7a46',
  array['folders_authoritative','tree_order_ids','tombstones','immutable_batch_contract_metadata','operation_attempt_history','operation_state_events','storage_name_v1'],
  repeat('a', 64), 'ID_BASED', 1, repeat('b', 64)
);
insert into public.sync_operations (
  operation_id, project_id, provenance_kind, batch_id, sequence,
  entity_kind, entity_id, intent_kind, base_revision, payload_sha256,
  payload, created_by
) values (
  '20000000-0000-4000-8000-000000000211',
  '00000000-0000-4000-8000-000000000201', 'CONTRACT_BATCH',
  '10000000-0000-4000-8000-000000000211', 1, 'folder',
  '30000000-0000-4000-8000-000000000201', 'rename', 2,
  repeat('c', 64), '{"name":"Later"}'::jsonb,
  '90000000-0000-4000-8000-000000000001'
);
select private.append_operation_event(
  '20000000-0000-4000-8000-000000000211',
  '70000000-0000-4000-8000-000000000211', 'enqueued'
);
select public.cancel_sync_operation(
  '20000000-0000-4000-8000-000000000211',
  '70000000-0000-4000-8000-000000000212'
);
select public.cancel_sync_operation(
  '20000000-0000-4000-8000-000000000211',
  '70000000-0000-4000-8000-000000000212'
);
select public.cancel_sync_operation(
  '20000000-0000-4000-8000-000000000211',
  '70000000-0000-4000-8000-000000000213'
);

do $assert_cancel$
declare v_count integer; v_state text;
begin
  select count(*) into v_count
  from public.sync_operation_events
  where operation_id = '20000000-0000-4000-8000-000000000211'
    and event_type = 'cancel_requested';
  select state into v_state from public.sync_operation_states
  where operation_id = '20000000-0000-4000-8000-000000000211';
  if v_count <> 1 or v_state <> 'cancelled' then
    raise exception 'cancellation derivation failed: count %, state %', v_count, v_state;
  end if;
end;
$assert_cancel$;

-- Row absence is LEGACY epoch 0. Manual begin is the only enforcement gate.
insert into public.projects(project_id, owner_id, name) values
  ('00000000-0000-4000-8000-000000000301',
   '90000000-0000-4000-8000-000000000001', 'Manual migration');
insert into public.project_members(project_id, user_id, role) values
  ('00000000-0000-4000-8000-000000000301',
   '90000000-0000-4000-8000-000000000001', 'owner');

do $assert_legacy_default$
begin
  if exists (
    select 1 from public.project_sync_settings
    where project_id = '00000000-0000-4000-8000-000000000301'
  ) then
    raise exception 'existing project was automatically promoted';
  end if;
end;
$assert_legacy_default$;

select public.begin_project_sync_migration(
  '00000000-0000-4000-8000-000000000301',
  '60000000-0000-4000-8000-000000000301',
  'fae86b4e6385ee37fbeb99f9256194ec319b64bfda92974ce90a3eb70d2e7a46'
);
select public.complete_project_sync_migration(
  '00000000-0000-4000-8000-000000000301',
  '60000000-0000-4000-8000-000000000301', 1
);

do $assert_manual_migration$
declare v_mode text; v_epoch integer;
begin
  select project_sync_mode, migration_epoch into v_mode, v_epoch
  from public.project_sync_settings
  where project_id = '00000000-0000-4000-8000-000000000301';
  if v_mode <> 'ID_BASED' or v_epoch <> 1 then
    raise exception 'manual migration failed: mode %, epoch %', v_mode, v_epoch;
  end if;
end;
$assert_manual_migration$;

select 'stage7_server_contract_sql_passed' as result;
