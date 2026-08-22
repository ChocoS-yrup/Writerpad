\set ON_ERROR_STOP on

begin;

select pg_catalog.set_config(
  'request.jwt.claim.sub',
  '90000000-0000-4000-8000-000000000801',
  false
);

insert into auth.users(id) values
  ('90000000-0000-4000-8000-000000000801');

insert into public.projects(project_id, owner_id, name) values
  ('00000000-0000-4000-8000-000000000801',
   '90000000-0000-4000-8000-000000000801',
   'Handshake contract');
insert into public.project_members(project_id, user_id, role) values
  ('00000000-0000-4000-8000-000000000801',
   '90000000-0000-4000-8000-000000000801',
   'owner');

-- Rollback keeps this enablement local to the test transaction.
update private.sync_contract_allowlist
set enabled = true
where canonical_contract_sha256 =
  '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670';

select public.get_sync_handshake(
  '00000000-0000-4000-8000-000000000801',
  '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670'
) as response \gset legacy_

select (
  (:'legacy_response'::jsonb->>'supported')::boolean
  and :'legacy_response'::jsonb->>'project_id' =
    '00000000-0000-4000-8000-000000000801'
  and :'legacy_response'::jsonb->>'project_sync_mode' = 'LEGACY'
  and (:'legacy_response'::jsonb->>'migration_epoch')::integer = 0
  and :'legacy_response'::jsonb->>'contract_version' = '0.2.0'
  and :'legacy_response'::jsonb->>'canonical_contract_sha256' =
    '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670'
  and :'legacy_response'::jsonb->>'server_contract_sha256' =
    '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670'
  and (:'legacy_response'::jsonb->>'server_protocol_version')::integer = 3
  and :'legacy_response'::jsonb->'supported_protocol_versions' = '[3]'::jsonb
  and pg_catalog.jsonb_array_length(
    :'legacy_response'::jsonb->'server_capabilities'
  ) = 8
  and :'legacy_response'::jsonb->'server_capabilities'
    ?& array[
      'atomic_structure_commit',
      'contract_allowlist_validation',
      'project_mode_migration_lock',
      'folder_tombstones',
      'id_tree_validation',
      'legacy_epoch_zero_adapter',
      'storage_name_v1',
      'document_commit_v1'
    ]::text[]
) as passed \gset legacy_assert_
\if :legacy_assert_passed
\else
  \quit 1
\endif

select public.get_sync_handshake(
  '00000000-0000-4000-8000-000000000801',
  '0000000000000000000000000000000000000000000000000000000000000000'
) as response \gset unknown_

select (
  not (:'unknown_response'::jsonb->>'supported')::boolean
  and :'unknown_response'::jsonb->>'contract_version' is null
  and :'unknown_response'::jsonb->>'canonical_contract_sha256' is null
  and :'unknown_response'::jsonb->>'server_contract_sha256' is null
  and :'unknown_response'::jsonb->>'server_protocol_version' is null
  and :'unknown_response'::jsonb->'supported_protocol_versions' = '[]'::jsonb
  and :'unknown_response'::jsonb->'server_capabilities' = '[]'::jsonb
) as passed \gset unknown_assert_
\if :unknown_assert_passed
\else
  \quit 1
\endif

insert into public.project_sync_settings (
  project_id, project_sync_mode, migration_epoch,
  contract_enforcement_started_at, active_contract_sha256
) values (
  '00000000-0000-4000-8000-000000000801', 'ID_BASED', 3,
  pg_catalog.transaction_timestamp(),
  '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670'
);

select public.get_sync_handshake(
  '00000000-0000-4000-8000-000000000801',
  '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670'
) as response \gset id_based_

select (
  (:'id_based_response'::jsonb->>'supported')::boolean
  and :'id_based_response'::jsonb->>'project_sync_mode' = 'ID_BASED'
  and (:'id_based_response'::jsonb->>'migration_epoch')::integer = 3
) as passed \gset id_based_assert_
\if :id_based_assert_passed
\else
  \quit 1
\endif

update private.sync_contract_allowlist
set enabled = false
where canonical_contract_sha256 =
  '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670';

select public.get_sync_handshake(
  '00000000-0000-4000-8000-000000000801',
  '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670'
) as response \gset disabled_

select (
  not (:'disabled_response'::jsonb->>'supported')::boolean
  and :'disabled_response'::jsonb->>'server_protocol_version' is null
  and :'disabled_response'::jsonb->'server_capabilities' = '[]'::jsonb
) as passed \gset disabled_assert_
\if :disabled_assert_passed
\else
  \quit 1
\endif

do $auth_boundaries$
begin
  perform pg_catalog.set_config('request.jwt.claim.sub', '', true);
  begin
    perform public.get_sync_handshake(
      '00000000-0000-4000-8000-000000000801',
      '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670'
    );
    raise exception 'unauthenticated handshake unexpectedly succeeded';
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'AUTH_REQUIRED' then raise; end if;
  end;

  perform pg_catalog.set_config(
    'request.jwt.claim.sub',
    '90000000-0000-4000-8000-000000000802',
    true
  );
  begin
    perform public.get_sync_handshake(
      '00000000-0000-4000-8000-000000000801',
      '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670'
    );
    raise exception 'non-member handshake unexpectedly succeeded';
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'FORBIDDEN' then raise; end if;
  end;
end;
$auth_boundaries$;

select (
  not pg_catalog.has_function_privilege(
    'anon', 'public.get_sync_handshake(uuid,text)', 'EXECUTE'
  )
  and pg_catalog.has_function_privilege(
    'authenticated', 'public.get_sync_handshake(uuid,text)', 'EXECUTE'
  )
  and (
    select procedure.provolatile = 's' and procedure.prosecdef
    from pg_catalog.pg_proc as procedure
    join pg_catalog.pg_namespace as namespace
      on namespace.oid = procedure.pronamespace
    where namespace.nspname = 'public'
      and procedure.proname = 'get_sync_handshake'
  )
) as passed \gset acl_assert_
\if :acl_assert_passed
\else
  \quit 1
\endif

rollback;

select 'authenticated_sync_handshake_sql_passed' as result;
