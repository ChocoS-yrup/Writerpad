# 제품 전환 실행 전 서버 점검 — 2026-09-28

이 문서는 PR #47 병합 직후 읽기 전용 조사 시점의 기록이다. 후속 사용자가 공통 서버
보강 구현을 승인했으며, 이어진 변경은 `server-migration-validation-hardening-2026-09-28.md`에 기록한다.

## 이번에 완료한 작업

- 사용자 승인에 따라 PR #47을 병합했다.
- GitHub CLI 확인: `MERGED`, 병합 시각 `2026-09-27T16:33:39Z`.
- 병합 커밋 및 동기화한 main: `4078c658b99b2a333171c62f18adb156bde9febc`.
- 최종 검토 head `1de0711deeb33e6ae9cc9b562b4f963444f3198b`와 병합 결과의
  소스 트리가 같음을 확인했다. 이전 626개 회귀/Release 결과를 이번에 재실행했다고 주장하지 않는다.
- PR: https://github.com/ChocoS-yrup/Writerpad/pull/47

## 읽기 전용 점검 범위

기존 저장소의 스테이징 기록과 일치하는 WriterPad Staging
(`mhpnszcorfzrvhyondxr`)에서 `pg_proc`, `pg_namespace`, `pg_constraint`,
`pg_trigger` 메타데이터만 SELECT했다. 원고·계정 행은 조회하지 않았다.
production 및 다른 프로젝트는 점검 대상으로 선택하지 않았다.

`begin_project_sync_migration`, `validate_project_sync_migration`,
`complete_project_sync_migration`, `get_project_status`의 배포된 정의·실행 권한,
folders/documents/tree_orders의 제약과 사용자 정의 트리거를 확인했다.
전환 RPC 호출, DDL, 데이터 변경, 배포, 백업/삭제/복원은 하지 않았다.

Supabase 스킬 및 Postgres best-practices의 최소 권한·트랜잭션 advisory lock 지침을
적용하여, 관리용 접속으로 시험 전환을 실행하는 대신 현재 함수/제약 정의만 확인했다.

## 확인된 공통 서버 검증 누락

현재 배포된 validator는 저장소의
`supabase/migrations/20260910072310_contract_migration_control_documents.sql`
정의와 동일한 검증 항목을 사용한다. 관리 문서 형식, 저장 이름, 폴더의 부모 존재,
형제 이름 충돌을 검사하지만 다음 항목은 검사하지 않는다.

1. **살아 있는 문서의 부모가 살아 있는 폴더인지**: 문서 FK는 같은 작품의 폴더 행 존재를
   보장하지만 `is_deleted = false`까지 보장하지 않는다. validator의 부모 검사는 폴더만 대상으로 한다.
2. **폴더 관계의 순환**: `folders_not_own_parent_ck`는 자기 자신을 부모로 지정하는 것만
   막는다. 두 개 이상 폴더의 순환은 이 CHECK와 FK로 배제되지 않는다.
3. **ID 기반 트리 참조의 유효성**: `tree_orders.children`의 각 UUID가 같은 작품의
   올바른 살아 있는 항목을 정확히 한 번 가리키는지 검사하지 않는다. 배열 원소에는 FK가 없다.

조회한 세 테이블에는 이를 대신 검사하는 사용자 정의 트리거도 없었다.
공유 계약 `sync-contract/protocol.json`의 `migration_validation`에는 위 검증이 명시되어 있다.
`complete_project_sync_migration`은 현재 validator의 `valid`를 확인한 뒤 `ID_BASED`로
전환하므로, 제품 실행 경로를 노출하기 전에 서버 완료 조건을 보강하는 것이 필요하다.

이는 **코드·메타데이터 검토 결과**다. 실제 스테이징 데이터가 위반 상태라는 뜻이 아니며,
잘못된 데이터를 삽입하여 전환에 성공한 재현 시험도 하지 않았다. 정상 쓰기 RPC 자체의
검증이 모두 잘못됐다고 주장하지 않는다. 클라이언트 사전 검사만으로 현재 공통 서버의
완료 조건이 강화되는 것은 아니다.

## 승인 경계와 제안 범위

이번에 승인된 PR #47의 iPad 읽기 전용 기능 범위를 넘어, 공통 서버 전환 완료 조건을
수정하는 단계에서 중단했다. 새 제품 전환 버튼, migration, 서버 로직은 아직 수정하지 않았다.

제안하는 다음 묶음:

- 기존 migration을 수정하지 않고 보강 migration을 추가한다.
- 정상 구조 및 관리 문서 예외를 유지하면서 삭제 부모·순환·잘못된 트리 참조를 거부한다.
- 전환 실패 시 모드/감사 기록 일관성과 기존 인증/권한 경계를 회귀 시험한다.
- 관련 변경을 한 PR에 묶고 최종 head에서 검토를 요청한다.
- Windows에도 실제로 적용되는 공통 서버 동작 변경이므로 이번 묶음은 Windows 검토 대상이다.
- PR 병합, 스테이징/production 적용, 실제 작품 전환은 이 구현 승인에 포함하지 않는다.

로컬 Docker daemon은 실행 중이지 않아 이 점검에서 DB 실행 시험을 하지 않았다.
다음 구현 시 격리 DB 또는 서버 CI의 실제 SQL 시험 결과를 확보해야 한다.

다음 단계 권장 모델: GPT-6 Sol / high. 공통 SQL 검증과 회귀 시험을 함께 다루는 구현 작업이다.
