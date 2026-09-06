# `get_sync_handshake` 응답 봉투

이 문서는 **정규 계약의 일부가 아니다.** 다이제스트는 `protocol.json` 한 파일의
RFC 8785 정규화 바이트에만 걸린다(`contract-lock.json`의 `protocol_path`). 이
파일을 고쳐도 `416c1b99…`는 바뀌지 않는다.

그럼에도 여기 적는 이유는, 2026-08-25까지 이 봉투가 **배포된 함수 몸통에만**
존재했기 때문이다. 두 클라이언트가 필수로 요구하는 키가 어느 저장소에도, 어느
명세에도 없었고, 스테이징을 내렸으면 같이 사라질 뻔했다.

## 봉투

`get_sync_handshake(p_project_id uuid, p_contract_sha256 text)`는 `jsonb` 하나를
돌려준다. 배포본이 내보내는 키는 열 개다.

| 키 | 형 | 비고 |
|---|---|---|
| `supported` | bool | 이 작품에 이 다이제스트로 계약 경로를 쓸 수 있는가 |
| `project_id` | uuid | 물은 작품이 맞는지 확인용 |
| `project_sync_mode` | text | `LEGACY` / `MIGRATING` / `ID_BASED` |
| `migration_epoch` | int | `LEGACY`는 0, 나머지는 1 이상 |
| `contract_version` | text? | `supported=false`면 null |
| `canonical_contract_sha256` | text? | allowlist 행이 말하는 정본 다이제스트 |
| `server_contract_sha256` | text? | 서버가 실제로 적용 중인 다이제스트 |
| `server_protocol_version` | int? | `allowed_protocol_versions`의 최대값 — **천장** |
| `supported_protocol_versions` | int[] | 서버가 지금 받아 주는 번호 전부 |
| `server_capabilities` | text[] | |

`supported=false`일 때 nullable 넷은 null, 배열 둘은 빈 배열이다.

## 클라이언트가 요구하는 것

**양쪽이 같지 않다.** 두 구현의 현재 상태를 그대로 적는다.

### 양쪽 공통

- `supported`가 참이 아니면 사용 불가
- `project_id`가 물은 값과 다르면 거절
- `server_contract_sha256` 부재 → 거절
- `server_protocol_version` 부재 → 거절
- 값이 있는데 어긋나면 거절: `canonical_contract_sha256 == server_contract_sha256`
  (다르면 서버가 자기 자신과 어긋나게 말한 것이라 어느 쪽도 고르지 않는다),
  `supported_protocol_versions`가 `server_protocol_version`을 포함할 것,
  그리고 **클라이언트가 쓰는 번호를 포함**할 것 — `server_protocol_version`은
  천장일 뿐이라 `>=` 검사만으로는 부족하다. 3을 내리고 4로 답하는 서버는 그
  검사를 통과하면서 우리가 할 수 있는 말은 전부 거절한다

### 2026-09-06 대조와 iPad 측 공통 정책 회신

기준: iPad `bb40d22164f34371f9ad7f70b9cddf208a692f83`, Windows
`a3eaa8b97dc9769ad313ac3fe579d0b1443849a9`. Windows 동작은 같은 날짜의
Windows–iPad 최종 대조 회신에서 제공한 모의 검사 결과다.

| 입력 | iPad | Windows 회신의 현재 동작 |
|---|---|---|
| `contract_version` 누락 | 거절 | 거절 |
| `canonical_contract_sha256` 누락 | 거절 | 거절 |
| `supported_protocol_versions` 누락 | 거절 | 거절 |
| `project_id` 누락 | 거절 | 승인 |
| protocol 목록 중복 또는 0 이하 포함 | 거절 | `[3,3]`, `[0,3]` 승인 재현 |
| capability 목록 중복 | 거절 | 승인 |

이전 문서의 “Windows가 필수 3개 필드 누락을 통과시킨다”는 설명은 수정 전
상태였다. 현재 Windows는 이 세 필드의 누락을 거절한다.

iPad 측은 **작품 ID 필수 및 요청값 일치, 양의 정수로만 구성된 중복 없는
protocol 목록, 중복 없는 capability 목록**을 공통 정책으로 채택하는 데
동의한다. iPad의 검사를 완화하지 않는다. Windows의 해당 보완과 회귀 검사가
완료됐다는 뜻은 아니며, 완료 회신을 받은 뒤 양쪽 일치로 판정한다.

`supported=true`일 때 `contract_version`은 클라이언트 pin `0.2.0`과 정확히
일치해야 한다. 이 설명 정정은 정규 계약 `protocol.json`, 잠금 파일, pin,
다이제스트 또는 서버 설정을 변경하지 않는다.

`server_protocol_version`과 `server_contract_sha256`이 빠진 응답은 두 클라이언트
모두 거절한다. `becbf42`의 `20260820113209_authenticated_sync_handshake.sql`이
그 둘을 내보내지 않아, 그 파일만으로 세운 서버에는 어느 쪽도 붙지 못한다.
배포본은 `20260825000000_restore_deployed_sync_handshake.sql`에 있다.

## 이 봉투를 계약에 올리는 문제

올리려면 `protocol.json`의 바이트가 바뀌고, 다이제스트가 바뀌고, 서버 allowlist
행과 두 클라이언트의 pin 상수를 동시에 갈아야 한다. 0.2.0은 `released`이므로
릴리스된 계약의 바이트를 고치는 일이 된다. **다음 계약 버전을 끊을 때 같이
넣는다.** 그때까지 이 문서가 그 자리를 대신한다.

## 구현

- 서버: `supabase/migrations/20260825000000_restore_deployed_sync_handshake.sql`
- iPad: `WriterPad/Sync/SyncV2Handshake.swift` (`SyncV2HandshakeResponse`,
  `SyncV2Contract.readHandshakeCompatibility`)
- Windows: `sync_contract.py` `read_handshake_compatibility` /
  `_require_coherent_handshake`
