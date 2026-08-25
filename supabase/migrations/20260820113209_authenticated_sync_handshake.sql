begin;

-- 클라이언트는 private allowlist나 row absence를 추측하지 않는다. 인증된 작품
-- 구성원이 자기 작품의 실제 mode/epoch와, 요청한 고정 다이제스트를 서버가
-- 현재 허용하는지를 한 응답에서 읽는다. 이 RPC는 읽기 전용이며 계약 쓰기를
-- 활성화하거나 project_sync_settings 행을 만들지 않는다.
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

  -- 행이 없다는 서버 계약의 의미만 여기서 LEGACY/0으로 해석한다. 클라이언트
  -- 저장소는 이 RPC가 성공하기 전까지 unknown(nil)을 유지한다.
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
    'supported_protocol_versions', case when v_supported
      then pg_catalog.to_jsonb(v_contract.allowed_protocol_versions)
      else '[]'::jsonb end,
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
