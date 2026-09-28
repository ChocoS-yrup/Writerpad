begin;

-- Keep the protocol-3 provenance boundary while accepting both released
-- contracts, provided the batch pin matches this project's active pin.
create or replace function private.enforce_document_write_boundary()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_mode text := 'LEGACY';
  v_active_contract_sha256 text;
begin
  select project_sync_mode, active_contract_sha256
  into v_mode, v_active_contract_sha256
  from public.project_sync_settings
  where project_id = new.project_id;
  if not found then v_mode := 'LEGACY'; end if;

  if v_mode <> 'LEGACY' and not exists (
    select 1
    from public.sync_operations operation
    join public.sync_batches batch on batch.batch_id = operation.batch_id
    where operation.operation_id = new.operation_id
      and operation.project_id = new.project_id
      and (operation.entity_kind = 'document' or (
        operation.entity_kind = 'trash_purge' and operation.intent_kind = 'update'
        and operation.entity_id = new.document_id
        and new.relative_path = '__antigravity__/trash-purge.json'
        and not new.is_deleted
        and operation.base_revision = new.base_revision
        and new.revision = new.base_revision + 1
        and operation.payload->>'content' = new.content
      ))
      and operation.provenance_kind = 'CONTRACT_BATCH'
      and batch.sync_protocol_version = 3
      and batch.project_id = new.project_id
      and batch.canonical_contract_sha256 = v_active_contract_sha256
      and batch.canonical_contract_sha256 in (
        '416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670',
        'abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c'
      )
  ) then
    raise exception using errcode = 'P0001', message = 'PROTOCOL_TOO_OLD';
  end if;
  return new;
end;
$$;

revoke all on function private.enforce_document_write_boundary() from public, anon, authenticated;

commit;
