begin;

-- Advertise one exact, currently enabled sync contract to an authenticated
-- project member. This function is read-only: it neither enables an allowlist
-- row nor creates or promotes project_sync_settings.
create or replace function public.get_sync_handshake(
  p_project_id uuid,
  p_contract_sha256 text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_mode text := 'LEGACY';
  v_epoch integer := 0;
  v_active_contract_sha256 text;
  v_contract private.sync_contract_allowlist%rowtype;
  v_server_protocol_version integer;
  v_supported boolean := false;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_project_id is null
     or p_contract_sha256 is null
     or p_contract_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;
  if not private.has_project_role(p_project_id, v_user_id, 'viewer') then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  -- Row absence is the server contract's authoritative LEGACY/epoch-0 state.
  select
    settings.project_sync_mode,
    settings.migration_epoch,
    settings.active_contract_sha256
  into v_mode, v_epoch, v_active_contract_sha256
  from public.project_sync_settings as settings
  where settings.project_id = p_project_id;

  if not found then
    v_mode := 'LEGACY';
    v_epoch := 0;
    v_active_contract_sha256 := null;
  end if;

  select * into v_contract
  from private.sync_contract_allowlist as allowlist
  where allowlist.canonical_contract_sha256 = p_contract_sha256
    and allowlist.enabled
    and allowlist.revoked_at is null
    and allowlist.valid_from <= pg_catalog.transaction_timestamp();

  if found then
    select max(protocol_version)
    into v_server_protocol_version
    from pg_catalog.unnest(
      v_contract.allowed_protocol_versions
    ) as protocol(protocol_version);

    v_supported := v_mode = 'LEGACY'
      or v_active_contract_sha256 = p_contract_sha256;
  end if;

  return pg_catalog.jsonb_build_object(
    'supported', v_supported,
    'project_id', p_project_id,
    'project_sync_mode', v_mode,
    'migration_epoch', v_epoch,
    'contract_version', case when v_supported
      then v_contract.contract_version else null end,
    'canonical_contract_sha256', case when v_supported
      then v_contract.canonical_contract_sha256 else null end,
    'server_contract_sha256', case when v_supported
      then v_contract.canonical_contract_sha256 else null end,
    'supported_protocol_versions', case when v_supported
      then pg_catalog.to_jsonb(v_contract.allowed_protocol_versions)
      else '[]'::jsonb end,
    'server_protocol_version', case when v_supported
      then v_server_protocol_version else null end,
    'server_capabilities', case when v_supported
      then pg_catalog.to_jsonb(v_contract.server_capabilities)
      else '[]'::jsonb end
  );
end;
$$;

revoke all on function public.get_sync_handshake(uuid, text)
  from public, anon, authenticated;
grant execute on function public.get_sync_handshake(uuid, text)
  to authenticated;

comment on function public.get_sync_handshake(uuid, text) is
  'Authenticated, read-only advertisement of project mode/epoch and one exact enabled sync-contract digest.';

commit;
