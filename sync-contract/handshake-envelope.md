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

양쪽의 합의 정책과 검증 출처를 구분해서 적는다.

### 양쪽 공통

- `supported`가 참이 아니면 사용 불가
- `project_id`는 유효한 UUID 문자열로 필수이며 요청 작품과 일치해야 한다
- `contract_version`은 pin `0.2.0`과 정확히 일치해야 한다
- 정본·서버 digest 모두 필수이며 서로 같고 클라이언트 pin과도 일치해야 한다
- `server_protocol_version`과 `supported_protocol_versions`는 필수다
- protocol 목록은 양의 정수로만 구성되고 중복이 없어야 한다. 서버 번호와
  클라이언트가 쓰는 번호 모두 포함해야 한다. 서버 번호는 천장이므로 단순한
  `>=` 비교로 목록 검사를 대신하지 않는다
- capability 목록에 중복을 허용하지 않고 필수 capability를 모두 요구한다

### 2026-09-06 최신 Windows 보완 회신 반영

iPad 기준은 `ab893843562e06e14f400d99e18870f1a97c3703`이다. Windows 기준 HEAD는
`a3eaa8b97dc9769ad313ac3fe579d0b1443849a9`이며 최신 C4·C5·C9와 계약 전송 정책
보완은 그 위의 **미커밋 작업 트리**라고 회신했다. 설치된 Windows 빌드의
동작으로 간주하지 않는다.

| 입력 | iPad 구현 | 최신 Windows 보완 회신 |
|---|---|---|
| `contract_version` 누락 | 거절 | 거절 |
| `canonical_contract_sha256` 누락 | 거절 | 거절 |
| `supported_protocol_versions` 누락 | 거절 | 거절 |
| `project_id` 누락·다른 UUID·숫자형 | 거절 | 거절 |
| protocol 목록 중복 또는 0 이하 포함 | 거절 | 거절 |
| capability 목록 중복 | 거절 | 거절 |

이전 표의 Windows `project_id` 누락·중복 목록 승인 내용은 C4 추가 보완 전
결과였다. 최신 회신에 맞춰 정정했다. 여기의 Windows 판정은 전달받은 보고에
근거하며 이 저장소에서 Windows 최신 소스를 독립 실행 검증한 결과는 아니다.

### 서버 작품 복원 후 재개 순서

계약 전송마다 새 `get_project_status`를 읽고, 요청 작품 ID와 `active` 상태를
확인한다. 일반 동기화의 호환 조회나 기본 active로 대신 승인하지 않는다.
Windows는 이미 알려진 비활성·구조 차단을 기존 복원/기준 재조회로 먼저
해소한다. iPad는 로컬 작품이 활성일 때 수동 송신의 새 상태 읽기로 서버 복원을
확인할 수 있지만, 최종 active·구조 기준·대기열·인증·관문 검사는 모두 필요하다.
두 클라이언트의 재개 순서가 같다는 뜻은 아니다.

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
