# 공통 서버 전환 검증 보강 — 2026-09-28

## 범위

PR #47 병합 main `4078c658b99b2a333171c62f18adb156bde9febc`에서 시작했다.
사용자는 전환 검증 보강의 구현·시험·PR 작성 범위 확장을 승인했다.
브랜치: `codex/server-migration-validation`.

기존 배포 migration은 수정하지 않는다. Supabase CLI가 생성한
`20260927164330_harden_project_sync_migration_validation.sql`에서 기존 validator만
교체한다. 파일 날짜는 CLI가 생성한 UTC 시각이며 문서 날짜는 한국 시각이다.
begin/complete RPC, 요청·응답 형태, 계약 0.2/0.3 pin, Swift/Windows 코드,
자동 승격/강등, 실제 데이터와 배포 상태는 바꾸지 않는다.

## 보강 내용

- 살아 있는 폴더와 일반 문서의 부모는 같은 작품의 살아 있는 폴더여야 한다.
- 모든 부모가 해석되면 null-parent 루트부터 도달하지 못하는 폴더를 순환 관계로 거부한다.
  루트에서 시작하는 탐색은 순환에 진입하지 않으므로 경로 배열을 무한히 늘리지 않는다.
- 실제 존재하는 tree_orders의 부모·참조를 검사한다. 잘못된 작품/부모, 삭제 항목,
  알 수 없는 ID, null, 다차원 배열, 중복 항목 및 folder/document 중복 ID를 거부한다.
- tree-order/trash-purge 관리 문서는 기존 UUID-v5·메타데이터 예외를 그대로 유지한다.
  유효한 관리 문서도 binder의 정렬 자식으로는 허용하지 않는다.
- 빈 작품, 정렬 행이 없는 작품, 일부 자식만 명시한 기존 자연 정렬 동작은 계속 허용한다.
  모든 빈 폴더에 정렬 행을 강제로 만들거나 본문을 수정하지 않는다.
- 기존 이름·충돌 검사 및 owner/editor 권한을 유지한다. standalone 검사도 완료 함수와
  같은 트랜잭션 project advisory lock을 사용한다.
  잠금 대기 중 권한이 철회될 수 있어 잠금을 얻은 뒤에도 membership을 다시 확인한다.

기존 응답 `issues` 배열에 기존 코드 `FOLDER_NOT_FOUND`, `FOLDER_CYCLE`,
`TREE_REFERENCE_NOT_FOUND`, `TREE_REFERENCE_DUPLICATED`를 사용한다.
트리 오류 count는 오류가 있는 정렬 행 수다. 순환 count는 순환 조상 때문에 루트에서
도달하지 못한 폴더 수다. 부모 오류가 있으면 이미 invalid이므로 순환 검사는 건너뛴다.

## 시험과 검토 경계

새 SQL 회귀는 격리 PostgreSQL에서 25개 정상/오류 fixture와 인증·권한 경계를 확인한다.
fixture 생성만 DB owner로 수행하고, 실제 begin/validate/complete는 authenticated 역할로
호출한다. 전체 fixture를 마지막에 rollback한다. **배포된 DB에서 실행하면 안 된다.**

- standalone 검사 전후 데이터·감사 기록 불변.
- 실패 시 MIGRATING/epoch 및 본문/구조/정렬 유지, validation_result만 기록.
- 성공 시 ID_BASED와 완료 감사 기록 확인, 본문/문서 ID 및 정렬 유지.
- 익명 실행 권한 없음, 비회원/viewer 거부, editor 검사 허용·완료 거부.
- owner도 틀린 epoch/device 또는 비활성 계약을 우회하지 못함.
- 다른 작품의 잘못된 정렬 참조가 대상 작품 검사에 섞이지 않음.
- 이전 validator로 새 회귀를 실행하면 `document_deleted_parent` 사례에서 반드시 실패해야 함.
- CI에서 전체 migration 설치·재적용 및 기존 서버 conformance도 함께 실행.
- 두 세션으로 잠금 대기 중 editor 권한 철회를 재현하고, 잠금 획득 후 FORBIDDEN을 확인.

첫 CI에서는 새 25개 사례와 권한 검사가 통과했으나 이전 버전 비교용 두 번째 DB에서
cluster-wide 역할을 중복 생성하여 시험 설정이 실패했다. 두 번째 bootstrap은 역할을
재생성하지 않도록 고쳤다. 그 뒤 서버 conformance와 이전 validator 음성 대조는 통과했다.
이를 최초 CI 전체 성공으로 기록하지 않는다. 최종 head에서는 추가 잠금 경합 시험까지 재검증한다.

로컬 계약 verifier, 11개 migration 정적 검사, Stage 7 harness 정적 검사는 통과했다.
클라이언트 canonical SHA-256은
`416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670`으로 동일하다.
실제 SQL 실행 결과와 최종 head 검토 상태는 PR에 기록한다. 실행 전부터 통과로 간주하지 않는다.

Supabase/Postgres 스킬의 최소 권한·잠금 지침을 적용했다. 로컬 Supabase advisor는
로컬 DB(127.0.0.1:54322)가 없어 연결 실패했다. 배포 DB를 대신 검사하거나 변경하지 않았다.
CI의 권한/search_path 시험은 수행하되 전체 advisor 통과로 표현하지 않는다.

공통 서버 완료 동작이 바뀌므로 **최종 head에서 Windows 읽기 전용 검토가 필요하다**.
한 PR로 묶으며 PR 병합·스테이징/production 적용·실제 작품 전환은 별도 승인 사항이다.
