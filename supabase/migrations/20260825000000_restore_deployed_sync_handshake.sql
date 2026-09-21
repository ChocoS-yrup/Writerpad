begin;

-- 살아 있는 스테이징에 도는 정의를 그대로 되살린다.
--
-- becbf42 의 20260820113209 은 supported_protocol_versions 만 돌려주고
-- server_protocol_version 과 server_contract_sha256 을 돌려주지 않는다. 그런데
-- 두 클라이언트가 그 두 키를 필수로 요구하므로, 그 파일만으로 세운 서버에는
-- 어느 쪽도 붙지 못한다. 계약 명세는 서버가 allowlist 를 권위로 삼아 digest 와
-- protocol 을 검증하라고 요구하는데, 이 정의가 그것을 구현한 쪽이다.
--
-- 명세로부터 다시 쓰지 않고 배포본을 옮긴다. 응답 봉투의 키 이름과 모양은 어느
-- 명세에도 적혀 있지 않고 오직 이 몸통에만 있었다. 다시 쓰면 두 클라이언트가
-- 기다리는 키와 어긋난다. 봉투를 계약 명세에 올리는 것은 별건이다.
--
-- 출처: supabase/_dump/staging-actual-20260825.sql

CREATE OR REPLACE FUNCTION "public"."get_sync_handshake"("p_project_id" "uuid", "p_contract_sha256" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
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
$_$;

ALTER FUNCTION "public"."get_sync_handshake"("p_project_id" "uuid", "p_contract_sha256" "text") OWNER TO "postgres";
REVOKE ALL ON FUNCTION "public"."get_sync_handshake"("p_project_id" "uuid", "p_contract_sha256" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_sync_handshake"("p_project_id" "uuid", "p_contract_sha256" "text") TO "authenticated";

commit;
