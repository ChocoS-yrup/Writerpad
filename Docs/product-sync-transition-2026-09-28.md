# 일반 앱의 명시적 동기화 형식 전환

기준: PR #49 병합 main `49585a509982b7564ace3a6a313bbea46f1f37ee`.
작업 PR: https://github.com/ChocoS-yrup/Writerpad/pull/50
이 문서는 구현 설명이다. 병합·DB 배포·실제 작품 전환 승인이 아니다.

## 승인된 구현

사용자는 일반 LEGACY 문서의 구조 초기화 공백을 해결하는 공통 서버 기능과
iPad 시작·검증·완료·재개, 회귀시험 및 PR 준비를 승인했다.
실제 작품 전환은 사용자 지시로 생략한다. Windows 저장소는 변경하지 않았다.

화면 경로: 서버 계정 및 작품 연결 → 작품의 **동기화 형식 전환·재개**.
먼저 대기 중인 기존 동기화를 마치고 전체·작품별 일반 동기화를 끈다.
전환 동안 해당 작품 편집과 다른 기기의 동기화도 중지해야 한다.

1. 계획·진행 상태 조회: 소유자만 조회하며 아무 구조/감사 행도 쓰지 않는다.
2. 전환 시작 및 구조 준비: 별도 확인 후 서버에서 원자적으로 수행한다.
3. 전환 검증: 조회만 수행하며 완료하지 않는다.
4. 전환 완료: 검증 성공 후 다시 명시적으로 확인해야 ID_BASED가 된다.
5. 일반 동기화 활성화: 전환과 별개인 기존 opt-in을 사용한다.

## 공유 계약의 식별

기존 `protocol.json`, 0.2.0 pin `416c1b99…`, 서버 0.3.0 pin `abbd234c…`는
바꾸지 않는다. 기존 스키마에 예약된 `project/migrate`를 사용하는 **별도 협상 확장**을
`sync-contract/migration-initialization-v1.json`에 정의했다.

- 확장 식별자: `migration-initialization-v1`.
- 정확한 UTF-8/LF 파일 바이트 SHA-256:
  `5c5736ec9bda42f80b75dd8f863bb01b0bba8cef1ebe96675333db634b560c81`.
- 이것은 base canonical contract digest를 대체하는 값이 아니다.
- 현재 확장은 base 0.2.0만 지원한다. 0.3 활성 작품을 임의로 다시 pin하지 않는다.
- 서버 discovery의 확장 SHA와 앱의 pin이 다르면 시작하지 않는다.
- 구서버에 새 RPC가 없는 경우도 지원하지 않는 것으로 처리한다.
- 확장 해시는 immutable operation payload 안에 포함돼 요청 digest의 보호를 받는다.
- 일반 Windows/iPad의 기존 folder/document/tree-order intent는 이전 dispatcher로 전달한다.
  기존 body RPC와 begin/validate/complete 함수는 재정의하지 않는다.

공통 성공/실패 의미가 추가되므로 Windows 읽기 전용 호환성 검토 대상이다.
Windows CI의 스키마/벡터/해시 검사는 Windows 실앱 시험의 대체가 아니다.

## 서버

신규 migration: `20260927181453_product_sync_transition_initialization.sql`.
CLI `migration new`로 생성했다. 과거 migration을 수정하지 않았다.

`get_project_sync_transition_plan`은 project advisory transaction lock 전후의 소유권을
확인하고 현재 mode/epoch/시작 기기와 frozen payload를 반환한다. 본문은 반환하지 않는다.
payload의 baseline은 정렬된 폴더·문서 메타데이터, 본문 SHA, 기존 ID 정렬을 포함한다.

`prepare_project_sync_transition`은 같은 잠금 아래 payload를 다시 계산·대조한 다음,
필요한 경우 기존 begin을 호출하고 기존 atomic 구조 RPC에 단일 project/migrate intent를
넘긴다. 실패는 예외로 올려 **begin·초기화·이 요청의 감사 기록까지 함께 rollback**한다.
성공은 MIGRATING에 머문다. 기존 migration을 재개할 때 시작 사용자/기기가 일치해야 한다.

일반 문서는 모든 구조 열이 null일 때만 초기화한다. name/parent는 저장된 경로와 실제
폴더 ID로 해석하며 추측한 ID, 이름 교정, 삭제 후 재생성은 사용하지 않는다.
부분 metadata, 누락/모호한 부모, 순환, 이름 충돌 등은 거부한다.
삭제 문서에도 구조를 부여하되 삭제 상태·본문·revision을 보존한다.

삭제 폴더와 새 live 폴더가 같은 경로를 갖는 이력은 그 자체로 오류가 아니다.
폴더 전체의 경로 중복을 일괄 거부하지 않는다. 이미 parent ID가 있는 문서는 해당 ID와
기록된 경로의 일치만 확인하며 기존 구조 revision을 보존한다. 구조가 없는 문서의 부모를
경로로 찾아야 할 때만 모든 live/tombstone 후보를 세어, 0개는 `FOLDER_NOT_FOUND`,
2개 이상은 `PATH_CONFLICT`로 거부한다. live 후보 하나를 임의로 선택해 과거 부모를
추측하지 않는다. legacy 정렬은 기존 규칙대로 살아 있는 폴더와 자식만 참조한다.

기존 ID 정렬이 없을 때만 legacy tree-order 관리 문서의 정확한 이름을 UUID로 투영한다.
`<root>`는 기존 클라이언트와 같은 `메인` 경로로 해석한다. 임의 이름 별칭이나 누락된
폴더를 만들지 않는다. UUID-v5 정렬 ID도 immutable payload에 저장한다.
이미 ID 정렬이 있는 혼합 상태는 legacy 명시 정렬과 일치해야 하며 자동으로 덮어쓰지 않는다.
자연 정렬/일부 자식만 명시한 기존 정책은 유지한다.

보존: document ID, relative_path, content, content revision, current_version_id,
삭제 상태, 문서 버전 이력, UUID-v5 관리 문서. 일반 초기화의 structure_revision만 1로
설정하고 기존 validator로 전체 결과를 검증한다. 과거 이력을 contract batch로 꾸미지 않는다.
초기화한 일반 문서의 updated_at/updated_by는 구조 변경 감사 정보로 갱신한다.
본문 revision은 그대로이며 관리 문서의 수정 시각도 보존한다.

현재 안전 한계는 폴더 1000개·문서 1000개다. 초과는 begin 전에 거부한다.
권한은 authenticated 소유자 경로에만 부여하고 private helper 직접 호출과 anon은 막는다.
기존 테이블 직접 쓰기 권한이나 service-role 키를 앱에 추가하지 않는다.

## iPad 복구·수명 경계

- 읽기 전용 binding lookup만 사용한다. 계획 조회가 초기 snapshot 복구를 유발하지 않는다.
- 계정·연결·작품 수명·앱 활동·화면·송신 설정 epoch를 네트워크 직전에 확인한다.
- 일반/legacy 대기열이 비어 있어야 쓰기를 시작한다. 새 작업이 생기면 전송 직전 다시 막는다.
  상태 조회는 대기열을 쓰거나 비우지 않는다.
- 전환 요청은 보내기 전에 계정/local/server/device에 묶인 별도 atomic 파일 journal에 저장한다.
  같은 앱의 여러 화면도 공유 actor를 사용하여 미확인 요청을 서로 덮어쓰지 않는다.
- 응답 유실 후에는 원래 batch/operation/payload를 재사용한다. 새 요청으로 몰래 대체하지 않는다.
- 서버가 baseline 변경을 명시적으로 거부하면 시작 전 실패임을 확인한 것이므로 그 요청만
  폐기하고 새 계획 조회를 허용한다. timeout/불명확한 오류는 journal을 유지한다.
- 완료 응답을 잃으면 다음 조회에서 ID_BASED를 확인한다. 자동으로 begin/complete하지 않는다.
- 검증 이후 계정/기기/연결/화면 등이 바뀌면 이전 검증 승인을 다시 사용할 수 없다.
- receive-only/고정 진단 실행에서는 새 쓰기 경로를 사용할 수 없다.

## 검증 및 배포 주의

SQL 회귀는 폐기형 `writerpad_stage7` CI DB에서만 실행하며 전체 transaction을 rollback한다.
일반/빈/삭제 문서, legacy 정렬, stale baseline, 충돌, 누락 부모, 부분 metadata,
다른 기기, editor 권한, 확장 해시 오류, 동일 요청 재시도/완료 후 재시도를 검사한다.
폴더 경로 재사용 8경로도 검사한다: 빈 작품, 참조되지 않는 재사용 경로, ID가 확정된
live/삭제 문서, 부모가 모호한 live/삭제 문서, legacy 정렬, 부모 경로가 유일한 하위 문서.
성공 경로의 prepare·validate·complete·replay와 본문·버전·폴더 이력 보존, 모호한
경로의 preflight 무변경 거부를 실제 authenticated RPC로 검증한다.
잠금 경합 시험은 기존 validator와 새 조회/prepare 각각의 대기 중 권한 철회를 검사한다.
Swift 회귀는 가짜 transport와 임시 journal을 사용한다. 실제 서버 전환 시험이 아니다.

로컬 Supabase advisor는 DB가 없어 127.0.0.1:54322 ECONNREFUSED였다.
배포되지 않은 새 SQL의 advisor 결과로 기존 staging 결과를 대신 제시하지 않는다.
함수 권한·실제 SQL 동작은 CI로 검증하며 advisor 무경고를 주장하지 않는다.

참고한 공식 지침: [Supabase Database Functions](https://supabase.com/docs/guides/database/functions),
[Postgres advisory locks](https://www.postgresql.org/docs/current/explicit-locking.html#ADVISORY-LOCKS).
Supabase·Postgres 스킬에 따라 최소 권한, 빈 search_path, 트랜잭션 잠금 및 잠금 후 권한
재확인을 유지했다. SQL 시험 때문에 staging을 변경하지 않았다.

병합·DB 적용은 별도 승인이다. 기존 staging ledger와 로컬 이력은 역사적 차이가 있으므로
원본 migration 디렉터리에 누적 db push를 하지 않는다. 추후 배포 승인 시 새 migration
1개만 정확히 선택하는 전용 묶음으로 identity·ledger·dry-run을 다시 확인해야 한다.
