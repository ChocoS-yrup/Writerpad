# WriterPad 7~18단계 실용 축약 지시서 v3

작성일: 2026-08-15  
대상: WriterPad Windows ↔ GitHub ↔ iPad ↔ Supabase 동기화 작업  
운영 전제: 불특정 다수에게 배포하지 않고 제작자 한 사람이 Windows와 iPad에서 사용하는 집필 프로그램

---

## 0. 결론

기존 18단계의 장황한 수동 검토와 반복 보고는 줄인다. 그러나 원고 손실, 중복 적용,
두 기기의 상태 분기와 잘못된 원격 변경을 막는 안전장치는 줄이지 않는다.

이번 작업은 다음 원칙으로 진행한다.

1. GitHub의 실제 공유 단위는 브랜치명이 아니라 정확한 commit SHA다.
2. 현재 released 계약은 `0.3.0`이며, Windows `9313cde` 인계의 `0.2.0` pin과 구분한다.
3. 현재 iPad 로컬 브랜치는 최신 `main` 위의 후속 브랜치가 아니라 오래된 기준선에서 갈라진
   미공유 작업이다. 그 브랜치를 그대로 계속하거나 통째로 병합하지 않는다.
4. 기존 구현은 폐기하지 않고 최신 `main`에서 기능군별로 선별 이식한다.
5. 독립 백업과 실제 복구 시연을 기능 구현보다 먼저 완료한다.
6. storage-name-v2는 양쪽 클라이언트가 같은 canonical vector bytes를 직접 읽어 검증한다.
7. durable queue, immutable operation, payload digest, replay와 atomic commit은 유지한다.
8. 실제 원고·미해결 incident·기존 프로젝트는 시험 fixture로 사용하지 않는다.
9. 원격 migration, allowlist, 프로젝트 승격과 실제 원고 연결은 별도 명시적 승인 대상이다.
10. 다음 세부 단계는 자동으로 시작하지 않는다.

반드시 유지할 문장:

```text
미해결 incident 프로젝트와 운영 서버 데이터는 변경하지 마라.
기존 프로젝트를 자동 승격하지 마라.
마지막 세 이름변경 사건은 보존된 증거에서 직접 원인이 확인되기 전까지 수정하지 마라.
```

---

## 1. 저장소와 기준 자료 구분

### iPad·계약·서버 저장소

```text
https://github.com/ChocoS-yrup/Writerpad
```

주요 경로:

- `Docs/CrossPlatformSyncGitWorkflow.md`
- `sync-contract/`
- `supabase/migrations/`
- `supabase/tests/`
- `WriterPad/`
- `WriterPadTests/`

### Windows 저장소

```text
https://github.com/ChocoS-yrup/WriterPad_main
```

두 저장소는 서로 다른 저장소다. 경로, 브랜치, PR, commit SHA와 `main`을 서로 섞지 않는다.

### 세 종류의 기준 자료

#### 일반 상황 공유 규칙

```text
repository: https://github.com/ChocoS-yrup/Writerpad
ref: 최신 origin/main의 정확한 SHA
path: Docs/CrossPlatformSyncGitWorkflow.md
```

#### 역사적 Windows → iPad 구현 인계

```text
repository: https://github.com/ChocoS-yrup/WriterPad_main
branch: codex/windows-post-stage8-stabilization
commit_sha: 9313cde92376c3be121fe589f7b52179098bdbfd
path: docs/ipad-contract-client-handoff.md
```

이 커밋은 protocol 3 구조, Windows 구현 경험과 실패 사례를 읽는 기준이다. 이 커밋에
기록된 계약 `0.2.0`을 현재 released 계약으로 오해하지 않는다.

#### 현재 released 계약

```yaml
contract_version: 0.3.0
contract_git_commit: 2705fcbda0be440a9d82a5e1919f2885c6166727
canonical_contract_sha256: abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c
canonical_contract_bytes: 24777
storage_name_algorithm: storage-name-v2
```

모든 새 구현은 최신 iPad `main`의 `sync-contract/contract-lock.json`과 위 pin이 여전히
일치하는지 다시 확인한다. 불일치하면 위 값을 관성적으로 사용하지 말고 `not-verified`로
보고하고 중단한다.

### 실제 공유 단위

```text
repository + exact commit_sha + base_main_sha + active contract pin + 검증 결과 + 인계표
```

미커밋 파일, 로컬 DB, 브랜치 최신 상태 또는 “최신 상태”라는 설명은 공유 단위가 아니다.

---

## 2. 2026-08-15 확인 기준선

다음은 이 지시서 작성 시 확인한 상태다. 새 작업에서는 반드시 다시 확인한다.

### iPad 로컬 작업 폴더

```yaml
branch: feat/sync-v2-structure-recovery
head_sha: aa870f908fed7838aa3a8392efaa71cd4ceddeea
local_tracking_origin_main: f67441cc6b1da0469cfae3be90edd7a4e57b5c2a
github_main_sha: cefb2d890e8e6940744d526dc30e7e110f83188c
common_ancestor: 20d60ea94da4cd2543db489ea240efa5db2f4091
local_unique_commits: 22
github_main_unique_commits_after_common_ancestor: 15
tracked_worktree_changes: false
untracked_entries: 14
local_head_available_on_github: false
```

`feat/sync-v2-structure-recovery`에서 checkout, switch, rebase, merge, stash, reset, clean 또는
파일 복원을 하지 않는다. untracked 파일은 사용자 작업으로 간주한다.

### iPad 로컬 구현에서 확인된 자산

- 계약 request builder와 response validator
- SQLite durable queue
- batch/operation ID와 payload digest
- append-only operation event 기록 기반
- restart recovery와 orphan recovery
- transition vector harness
- 빠른 이름변경 진단시험
- frozen casefold 구현과 Unicode 측정 자료

### iPad 로컬 구현에서 확인된 미완료·위반

- 빌드 pin은 아직 계약 `0.2.0`이다.
- 실제 네트워크 호출은 여전히 `commit_document`와 `commit_folder`다.
- operation event가 존재하지만 다수의 큐 SQL은 mutable `status` 컬럼을 직접 읽는다.
- rebase가 기존 operation ID의 payload를 제자리에서 바꾸는 계약 위반이 남아 있다.
- Foundation NFKC의 supplementary-plane 오동작을 허용하는 계약 위반이 남아 있다.
- 빠른 이름변경 진단시험은 강제로 `PATH_CONFLICT`를 발생시키므로 과거 incident의 직접 원인
  증거가 아니다.
- targeted XCTest `169 passed / 0 failed`는 위 두 계약 위반을 의도적으로 고정한 시험까지
  포함하므로 release-ready 증거가 아니다.

### GitHub 상태

```yaml
ipad_main_sha: cefb2d890e8e6940744d526dc30e7e110f83188c
windows_main_sha: 221db4fa69e06210c0afad16870ccb25ef015094
windows_stabilization_draft_head: 9313cde92376c3be121fe589f7b52179098bdbfd
```

Windows에는 `9313cde`를 head로 하는 draft PR과 그 위에 쌓인 Unicode 조사 PR들이 있다.
Windows storage-name-v2 작업을 `main`에서 바로 시작하면 안정화 커밋을 누락할 수 있으므로,
Windows 단계 시작 전에 사용할 정확한 base SHA를 먼저 확정한다.

### 원격 Supabase 상태

이 지시서 작성 중 실제 Supabase에는 접속하지 않았다. 다음은 새 원격 작업 전에 모두
read-only로 다시 확인하며, 확인 전 값은 `not-verified`다.

- project identity
- migration ledger와 pending migration
- 진행 중 project migration
- allowlist exact row와 enabled 상태
- 기존 incident fixture fingerprint
- enabled allowlist row 총수

---

## 3. 공통 작업 시작 블록

아래 블록은 Windows, iPad, contract 또는 server 단계의 공통 머리말로 사용한다.
대괄호 필드는 단계별 실제 값으로 채운다.

#### 여기부터

```text
이번 작업에는 Windows–GitHub–iPad 상황 공유 절차를 적용해라.

## 저장소 구분

- iPad·계약·서버 저장소:
  https://github.com/ChocoS-yrup/Writerpad
- Windows 저장소:
  https://github.com/ChocoS-yrup/WriterPad_main

두 저장소는 서로 다른 저장소다. 경로, 브랜치, main과 commit SHA를 혼동하지 마라.

먼저 iPad 저장소 최신 origin/main의 정확한 SHA에서 다음 문서를 읽고 작업 전체에 적용해라.

Docs/CrossPlatformSyncGitWorkflow.md

GitHub는 실행 중인 로컬 폴더를 실시간 공유하는 공간이 아니다.
공유 가능한 상태는 commit·push된 내용과 정확한 commit SHA뿐이다.
미커밋 파일이나 “최신 상태”라는 설명을 상대 플랫폼이 볼 수 있다고 가정하지 마라.

## 역사적 Windows 인계

다음 커밋의 문서는 Windows protocol 3 구조와 이미 확인된 실패 사례를 읽는 용도로 사용해라.

repository: https://github.com/ChocoS-yrup/WriterPad_main
commit_sha: 9313cde92376c3be121fe589f7b52179098bdbfd
handoff_document: docs/ipad-contract-client-handoff.md

브랜치 최신 상태가 아니라 정확한 commit_sha의 파일을 확인해라.
이 문서의 계약 0.2.0 pin을 현재 released 계약으로 사용하지 마라.

## 현재 계약 기준

계약은 iPad 저장소의 다음 exact commit과 최신 main의 lock을 함께 확인해라.

contract_version: 0.3.0
contract_git_commit: 2705fcbda0be440a9d82a5e1919f2885c6166727
canonical_contract_sha256: abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c

lock과 불일치하면 추측해서 진행하지 말고 not-verified로 보고해라.

## 이번 작업 대상

target_platform: [ipad | windows | contract | server | evidence]
target_repository: [정확한 repository URL]
base_main_sha: [이번 단계에서 검증한 전체 SHA]
counterpart_result_sha: [있으면 전체 SHA, 없으면 not-applicable]
stage_id: [이번 단계 ID]

## 작업 시작 전 보고

코드를 수정하기 전에 다음을 먼저 보고해라.

1. target repository의 현재 브랜치와 전체 HEAD SHA
2. GitHub의 최신 origin/main 전체 SHA
3. local tracking origin/main이 최신인지
4. working tree의 기존 변경과 untracked 파일 여부
5. Windows 9313cde 문서를 실제로 읽었는지 또는 not-applicable인 이유
6. active contract_version
7. active contract_git_commit
8. active canonical_contract_sha256
9. 이번 단계의 정확한 base SHA
10. 이번 단계에서 수정할 파일
11. 수정하지 않을 파일과 금지 작업
12. counterpart 인계와 현재 구현 사이의 차이
13. 실행할 자동시험

기존 로컬 변경은 사용자 작업으로 간주하고 덮어쓰거나 삭제하지 마라.
dirty 메인 worktree에서 checkout, switch, merge, rebase, stash, reset, clean 또는 파일 복원을 하지 마라.

구현이 필요하면 지정된 exact base SHA에서 별도의 clean worktree와
codex/<플랫폼>-<주제> 브랜치를 만들어라.
latest main 이외의 base가 필요하면 그 이유와 exact SHA를 먼저 보고하고 사용자 결정을 받아라.

## 단계 작업 규칙

- 한 브랜치에는 하나의 판정 가능한 목적만 넣어라.
- 계약 변경, 플랫폼 구현, server 변경과 incident 증거 보존을 섞지 마라.
- 허용된 파일만 수정해라.
- 공통 vector 기대값을 구현 결과에 맞춰 바꾸지 마라.
- 관련 테스트와 계약 검증을 실행해라.
- 검증 후 의도적인 commit으로 만들고 push해라.
- 상대 플랫폼에는 브랜치명만 전달하지 말고 전체 commit SHA를 전달해라.
- 다음 세부 단계는 자동으로 시작하지 마라.
- 원격 변경, PR merge와 release는 별도 승인이 없으면 수행하지 마라.
- 상대 플랫폼 검토가 끝나기 전 PR은 draft 상태로 유지해라.
- 양쪽 구현이 main에서 도달 가능하기 전 공유 종단간 검증 완료를 선언하지 마라.

미해결 incident 프로젝트와 운영 서버 데이터는 변경하지 마라.
기존 프로젝트를 자동 승격하지 마라.
마지막 세 이름변경 사건은 보존된 증거에서 직접 원인이 확인되기 전까지 수정하지 마라.

## 완료 보고

아래 인계표의 모든 필드를 유지해라. 해당하지 않는 필드는 삭제하지 말고
not-applicable로 기록해라. 확인하지 못한 외부 상태는 not-verified로 기록해라.

handoff_version: 1
stage_id:
platform:
repository:
branch:
commit_sha:
base_main_sha:
contract_version:
contract_git_commit:
canonical_contract_sha256:
test_run_id:
server_project_id:
client_build_id_or_sha256:
changed_paths:
validation_commands:
validation_results:
incident_artifact_paths_or_urls:
known_limitations:
requested_counterpart_action:

requested_counterpart_action에는 상대 플랫폼 담당자가 확인할 exact SHA, 실행할 검증과
중단 조건을 구체적으로 적어라.
```

#### 여기까지

### 운영 부담 축약 규칙

- 위 전체 인계표는 플랫폼 간 인계, server/contract 변경, 원격 검증과 merge gate에 사용한다.
- 같은 브랜치 안의 로컬 조사 메모마다 인계표를 반복하지 않는다.
- 자동시험이 판정 가능한 항목은 장문의 수동 출력 비교로 반복하지 않는다.
- 실제 incident가 아니면 evidence 브랜치를 만들지 않는다.
- PR은 contract, server, cross-platform sync와 데이터 위험 변경에 사용한다.
- merge는 크기와 관계없이 사용자 승인 후 수행한다.

---

## 4. 선행단계 — 독립 백업과 복구 시연

### 확인된 현재 한계

- Windows 자동백업은 작품 workspace 내부의 문서별 5분 snapshot이다.
- Windows retention은 최근 이력을 간격별로 줄이지만 프로젝트 전체 독립 백업은 아니다.
- iPad `LocalBackupStore`는 작품 workspace 내부의 문서별 TXT·JSON snapshot이다.
- iPad TXT/PDF 내보내기는 구조·UUID manifest가 없는 소장용 출력이며 복구용 백업이 아니다.
- 전체 프로젝트를 독립 위치에서 복구해 본 증거는 `not-verified`다.

### 구현 지시

```text
Windows와 iPad의 기존 백업을 먼저 읽기 전용으로 감사하고, 프로젝트 전체 독립 백업과
복구 절차를 마련해라.

목표 백업:

1. 프로젝트 전체 폴더와 원고를 사람이 읽을 수 있는 UTF-8 파일로 포함
2. project/document/folder UUID, 상대 경로와 해시를 manifest에 포함
3. 원본 workspace와 다른 사용자가 선택한 로컬 경로에 저장
4. 두 번째 위치로 복제 가능한 단일 디렉터리 또는 archive 형식
5. 기본 30일 보관 정책은 구현하되 기존 백업 삭제는 별도 승인
6. 임시 복구 폴더에서 manifest와 파일 해시를 검증하고 실제 구조 복원 시연
7. 원본 workspace, 실제 원고와 기존 백업을 덮어쓰지 않음

먼저 감사 결과와 최소 형식을 보고해라. Windows와 iPad 구현은 별도 저장소·별도 commit으로
나눠라. 한 플랫폼에서 독립 전체 백업과 복구 시연을 먼저 완성한 뒤 상대 플랫폼을 진행해라.

완료 조건은 archive 생성이 아니라 임시 위치에서 문서 내용, 폴더 구조, ID와 해시가
일치함을 확인하는 것이다.
```

---

## 5. Stage 7 — non-superuser harness 최소 수정과 원격 검증 분리

기준 GitHub main:

```text
cefb2d890e8e6940744d526dc30e7e110f83188c
```

이 기준에는 Stage 7 harness가 병합돼 있지만 다음 session-level 문장이 남아 있다.

```sql
set plpgsql.variable_conflict = error;
```

### 로컬 코드 수정 단계

```text
cefb2d890e8e6940744d526dc30e7e110f83188c에서 새 clean worktree와
codex/server-stage7-nonsuperuser-harness 브랜치를 만들어라.

허용 파일:

- supabase/tests/stage7_revalidation_fingerprint_helpers.sql
- supabase/tests/stage7_staging_revalidation_harness.sql
- non-superuser 회귀시험 파일 1개
- 필요한 경우 그 시험을 실행하는 최소 workflow 변경

구현:

- session-level SET 의존 제거
- 각 PL/pgSQL 함수 본문에 #variable_conflict error 유지
- main harness의 declarative assertion과 실행 순서 유지
- fingerprint 규약, psql 변수, include 순서와 functional assertion 변경 금지

검증:

- PostgreSQL 17.6 관리자 역할
- 해당 SET 권한이 없는 비슈퍼유저 역할
- helper/harness compile과 execute
- 의도적 ambiguous reference가 계속 실패하는지
- fingerprint와 harness SHA-256
- 기존 contract/server 검증
- git diff --check

production RPC, migration, contract, allowlist와 원격 데이터는 변경하지 마라.
commit·push·인계 후 중단해라. 원격 Stage 7 실행은 자동 시작하지 마라.
```

### 원격 실행 단계

로컬 수정 exact SHA의 CI와 diff가 통과한 뒤 별도 승인을 받아 WriterPad Staging에서 한 번만
실행한다. 원격 실행 전 project identity, ledger, allowlist와 기존 fixture fingerprint를
read-only로 확인한다. 첫 불일치에서 중단한다.

---

## 6. Windows 기준선 결정 게이트

Windows storage-name-v2 구현 전에 다음 중 하나를 사용자에게 제시하고 하나만 선택받는다.

1. draft 안정화 PR의 exact head `9313cde…`를 검토·병합하고 새 Windows `main`에서 시작
2. 병합을 미룬 채 `9313cde…`를 명시적 base로 새 stacked 작업을 시작

권장은 1번이다. 새 Stage 8을 현재 Windows `main` `221db4fa…`에서 바로 시작하거나,
열린 Unicode PR #4~#6의 최신 branch 이름만 보고 기반을 정하지 않는다.

결정 전에는 Windows Stage 8 코드를 수정하지 않는다.

---

## 7. Stage 8 — Windows storage-name-v2

```text
Windows 기준선 결정 게이트에서 승인된 exact base SHA에서 clean worktree와
codex/windows-storage-name-v2 브랜치를 만들어라.

계약 source:
repository: https://github.com/ChocoS-yrup/Writerpad
contract_git_commit: 2705fcbda0be440a9d82a5e1919f2885c6166727
contract_version: 0.3.0
canonical_contract_sha256: abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c
vector: sync-contract/conformance_vectors/storage-name-v2.json

요구:

- 계약의 frozen assignment, exclusion과 casefold 자산 직접 사용
- pre-NFKC supplementary adjacency 거부
- post-NFKC separator 거부
- defensive post-NFKC baseline 재검사
- 검사 순서와 error code 유지
- storage-name-v1과 LEGACY 경로 보존
- 0.3.0 allowlist가 비활성인 동안 기존 client pin과 쓰기 경로를 임의 전환하지 않음
- 기존 Unicode 조사 PR은 참고만 하고 released asset bytes를 우선

시험:

- SN-001..SN-029 전량
- vector file SHA-256
- accept/reject, error code와 normalized UTF-8 bytes
- frozen resource 누락 시 실패
- 기존 v1 회귀
- Windows 패키징 환경에서 resource 포함 확인

원격 Supabase, iPad 코드, contract와 migration은 수정하지 마라.
commit·push·전체 result SHA 인계 후 중단해라.
```

---

## 8. Stage 9 — iPad storage-name-v2

```text
최신 iPad origin/main exact SHA에서 clean worktree와 codex/ipad-storage-name-v2 브랜치를 만들어라.

Windows counterpart는 Stage 8의 전체 result SHA만 사용해라.
현재 로컬 feat/sync-v2-structure-recovery 브랜치를 merge하거나 통째로 cherry-pick하지 마라.

계약 source와 vector는 Stage 8과 동일한 exact bytes를 사용해라.

구현:

- pure storage-name-v2 알고리즘과 resource loader를 독립된 책임으로 추가
- released Unicode 자산을 Xcode target resource에 등록
- Foundation 런타임 판에 결과를 맡기지 않음
- pre-NFKC supplementary adjacency 거부
- post-NFKC separator 거부
- defensive post-NFKC baseline 재검사
- storage-name-v1과 기존 PathPolicy 동작 보존
- 기존 프로젝트와 contract pin 자동 전환 금지
- 로컬 브랜치의 frozen casefold 구현은 참고할 수 있으나 released 자산과 다른 로컬 JSON은 사용 금지

시험:

- SN-001..SN-029 전량
- Windows exact commit과 vector SHA-256 일치
- 각 vector의 result와 UTF-8 bytes 일치
- NFC/NFD 한글, Cherokee, Cyrillic, U+0130, Straße
- supplementary adjacency와 post-NFKC separator
- resource 미등록 시 실패
- 기존 v1과 PathPolicy 회귀
- clean build와 XCTest

원격 Supabase, Windows 코드, contract와 migration은 수정하지 마라.
commit·push·전체 result SHA 인계 후 중단해라.
```

---

## 9. Stage 10~11 — 공유 vector gate와 merge readiness 통합

별도 vector 파일이나 장문의 수동 비교 문서를 만들지 않는다. Stage 8과 9가 canonical
vector를 직접 읽었으면 이 단계는 read-only 판정만 수행한다.

```text
Windows와 iPad storage-name-v2 결과를 exact commit SHA 기준으로 검토해라.

확인:

1. 두 result SHA가 실제 repository에서 도달 가능한 commit인가
2. 두 구현이 contract 0.3.0과 같은 vector bytes를 사용하는가
3. vector SHA-256과 결과 요약 digest가 같은가
4. SN-001..SN-029와 v1 회귀가 모두 PASS인가
5. Windows package와 Xcode target에 frozen assets가 포함됐는가
6. contract pin 또는 project mode 자동 전환이 섞이지 않았는가
7. 원격 DB, migration과 allowlist 변경이 diff에 없는가

blocking finding이 없으면 MERGE_READY와 검토한 전체 SHA를 보고해라.
사용자의 명시적 merge 승인 전에는 merge하지 마라.
승인 후 각 repository의 실제 merge SHA를 기록하고 중단해라.
```

---

## 10. Stage 12 — 빠른 이름변경 incident 증거 판정

이 단계는 기본적으로 evidence/read-only 단계다. 재현시험을 incident 원인 증명으로 바꾸지 않는다.

```text
보존된 마지막 세 이름변경 incident와 현재 양쪽 구현을 읽기 전용으로 대조해라.

금지:

- incident 프로젝트, 원본 DB, snapshot과 서버 row 수정
- 기존 fixture 정리·재분류·삭제
- 합성 PATH_CONFLICT를 실제 incident 원인으로 간주
- 원인이 확인되지 않은 상태에서 incident 수정 커밋 생성

먼저 확인:

- 당시 Windows/iPad exact commit과 build
- contract, project mode, migration epoch
- 여섯 operation ID, sequence, batch, base revision과 event/attempt history
- 네 번째 operation이 terminal, conflict, blocked, retry 또는 유실 중 어디에 있었는지
- 마지막 세 작업이 dispatch 대상에서 제외된 직접 조건

직접 원인이 증거에서 확인되면 원인, 재현 조건과 영향만 보고하고 중단해라.
수정은 별도 구현 단계로 제안하고 자동 시작하지 마라.

직접 원인이 확인되지 않으면 incident_causality: not-verified로 기록해라.
합성 rapid-six-renames 시험은 generic queue/atomicity 회귀 gate로 유지할 수 있지만
incident가 해결됐다고 선언하지 마라.
```

---

## 11. Stage 13 — protocol 3 기반 선별 이식과 계약 위반 제거

현재 로컬 브랜치 22커밋을 통째로 합치지 않는다. 최신 iPad `main`의 clean worktree에서
다음 기능군만 선별 이식한다.

```text
목적:

- immutable batch와 operation persistence
- payload digest와 exact replay
- append-only attempt/event
- restart recovery와 orphan recovery
- fail-closed contract compatibility
- canonical request/response builder

반드시 함께 제거할 위반:

1. rebase가 원본 operation ID의 base revision 또는 payload를 제자리에서 바꾸는 동작
2. Foundation NFKC supplementary-plane 오동작을 허용하는 storage-name 경로
3. active/terminal 판정을 mutable status column만으로 결정하는 읽기 경로

원칙:

- rebase는 새 batch_id와 operation_id를 만들고 supersedes_operation_id로 원본을 가리킴
- 원본 operation과 payload는 불변
- completed/cancelled 뒤 event append 금지
- current error와 pending count는 active derived state만 반영
- 상태 컬럼을 호환용 projection으로 유지할 수 있으나 event-derived state와 divergence 0을 gate로 사용
- canonical JSON을 sortedKeys나 sort_keys=True로 단순 교체 금지
- contract vector의 숫자, Unicode key, escape와 nested object bytes 일치
- 실제 네트워크 RPC 전환은 Stage 14와 15로 분리

필수 시험:

- exact batch replay
- same ID/different payload 거부
- immutable rebase와 supersession
- response loss
- offline 작성 후 online 전환
- 강제 종료 후 queue 복구
- orphan recovery
- event-derived pending/error/count
- sequence gap
- terminal failure 무한 재시도 방지
- transition vector 전량
- known contract violation 이름을 가진 기존 시험 제거 또는 준수 시험으로 교체

원격 Supabase, contract, migration, allowlist와 incident data는 수정하지 마라.
검증·commit·push·인계 후 중단해라.
```

---

## 12. Stage 14 — document_commit 실제 배선

```text
Windows와 iPad의 문서 저장 경로를 canonical document_commit RPC에 연결해라.

로컬 enum 또는 request builder 존재를 실제 RPC 배선 증거로 간주하지 마라.
실제 network transport의 RPC 이름과 request bytes를 시험해라.

요구:

- 검증된 immutable batch/operation metadata 사용
- empty content 유효 저장
- content SHA-256과 UTF-8 byte count 일치
- revision conflict에서 immutable rebase
- exact replay와 response-loss replay
- document update가 name, parent_folder_id와 structure_revision을 바꾸지 못함
- server success 검증 뒤에만 terminal 처리
- inflight restart recovery
- LEGACY/storage-name-v1 경로 보존

시험:

- create, update, empty, delete와 restore
- stale revision
- response loss replay
- same operation ID/different content
- structure field 변경 거부
- offline queue와 restart recovery

플랫폼별 별도 commit을 사용한다. 원격 staging 시험은 별도 승인 후 새 합성 프로젝트에서만 한다.
```

---

## 13. Stage 15 — atomic_structure_commit 실제 배선

```text
Windows와 iPad의 구조 변경 경로를 canonical atomic_structure_commit RPC에 연결해라.

요구:

- batch sequence 1부터 연속
- 전체 성공 또는 전체 rollback
- 부분 적용 금지
- exact replay와 response-loss replay
- same batch ID/different payload 거부
- revision과 structure_revision 정합
- restart 후 pending structure queue 복구
- 기존 LEGACY 프로젝트와 storage-name-v1 보존

generic 필수 시험:

- folder create, rename, move, delete와 restore
- 같은 이름의 서로 다른 folder ID
- folder/document/tree order 복합 batch
- 중간 intent 실패 전체 rollback
- response loss exact replay
- changed-payload ID reuse
- rapid six renames 전부 terminal
- restart recovery
- 양쪽 pending count 0 수렴

rapid-six 시험 통과는 generic atomicity 증거다. 보존 incident의 직접 원인이 확인되지 않았다면
incident_fixed 또는 incident_root_cause_confirmed를 선언하지 마라.

원격 staging은 별도 승인과 새 합성 fixture로만 실행한다.
```

---

## 14. Stage 16 — 합성 staging E2E

```text
WriterPad Staging의 새 합성 사용자·프로젝트에서만 양쪽 동기화를 검증해라.

실행 전 read-only 확인:

- 정확한 project identity
- migration ledger와 pending migration 0
- 진행 중 project migration 0
- contract 0.3.0 exact allowlist row
- Windows/iPad main SHA와 build ID
- 합성 ID 미사용 여부

allowlist 변경이 필요하면 exact row 하나의 guarded 변경을 별도 승인받아라.

시나리오:

- Windows create → iPad pull
- iPad update → Windows pull
- NFC/NFD 한글 수렴
- 동일한 invalid name 거부
- document lifecycle
- folder rapid-six rename
- offline 작성 후 online 복귀
- response-loss replay
- 강제 종료 후 queue recovery
- 근접 동시 수정에서 silent loss 없음
- 양쪽 pending count 0
- server/local structure와 revision 수렴

첫 불일치에서 중단하고 기대값, fixture 또는 server row를 보정하지 마라.
PASS해도 실제 원고 연결, 기존 프로젝트 승격과 다음 단계를 자동 시작하지 마라.
```

---

## 15. Stage 17~18 — 개인 실사용 준비와 승인된 활성화

### Stage 17 read-only gate

다음을 모두 확인한다.

1. Windows 전체 프로젝트 독립 백업 존재
2. iPad 전체 프로젝트 독립 백업 존재
3. 양쪽 임시 복구 시연 PASS
4. exact release SHA와 build ID
5. Stage 16 합성 E2E PASS
6. storage-name-v1과 LEGACY 경로 유지
7. 자동 프로젝트 승격 코드 없음
8. 이전 client build와 rollback 절차 확보
9. exact allowlist row를 false로 되돌리는 절차
10. 실제 사용할 Supabase project ref와 프로젝트가 사용자에 의해 명시됨

하나라도 없으면 `BLOCKED` 또는 `not-verified`로 보고한다. 이 단계에서는 원격 변경, 앱 설치,
실제 원고 업로드를 수행하지 않는다.

### Stage 18 승인된 활성화

다음 값이 포함된 사용자 승인이 있을 때만 실행한다.

```text
server_project_ref:
windows_release_commit_sha:
windows_build_sha256:
ipad_release_commit_sha:
ipad_build_id:
contract_version:
canonical_contract_sha256:
allowlist_exact_row:
connected_project:
```

활성화는 exact allowlist row, 승인된 build와 지정 프로젝트 하나에만 수행한다. 기존 프로젝트는
LEGACY/기존 epoch를 유지하고 자동 승격하지 않는다. 문제가 생기면 신규 쓰기를 중단하고,
allowlist 비활성화·이전 build·새 별도 복구 위치를 사용한다. 실패 데이터를 임의 삭제하지 않는다.

---

## 16. 축약된 실제 실행 순서

```text
[A] 독립 전체 백업 + 실제 복구 시연
 ↓
[B] Stage 7 non-superuser 최소 수정 + 승인된 staging 1회 검증
 ↓
[C] Windows 기준선 결정
 ↓
[D] 양쪽 storage-name-v2 구현 + 하나의 공유 vector/merge gate
 ↓
[E] incident 증거 read-only 판정
 ↓
[F] 최신 iPad main에 protocol 3 기반 선별 이식 + 알려진 계약 위반 제거
 ↓
[G] document_commit 배선
 ↓
[H] atomic_structure_commit 배선 + generic rapid-six gate
 ↓
[I] 합성 staging E2E
 ↓
[J] 백업·rollback gate 후 승인된 개인 실사용 활성화
```

단계 번호는 기존 추적을 위해 유지하지만 운영상 별도 구현 묶음은 위 10개다. Stage 10과 11은
하나의 read-only gate로 합치며, Stage 12는 incident 수정 단계가 아니다.

---

## 17. 별도 승인이 필요한 작업

- Supabase 원격 migration 적용
- allowlist enabled/revoked 변경
- 원격 합성 fixture 생성 또는 변경
- 실제 원고 DB 연결
- 기존 프로젝트 mode, epoch 또는 active digest 변경
- 프로젝트 승격 또는 강등
- 실제 원고 업로드·삭제·이름 일괄변경
- incident 프로젝트·fixture 변경
- PR merge
- release build 배포와 client 설치
- 임시 DB 역할 또는 자격증명 발급
- 기존 백업 삭제와 retention 정리

다음은 범위가 정확하면 별도 승인 없이 진행할 수 있다.

- read-only 코드, exact diff, PR과 CI 확인
- clean worktree 생성
- 승인된 base에서 허용 파일의 로컬 구현
- 로컬 자동시험
- 의도적인 commit과 branch push
- canonical vector 기반 양쪽 결과 비교

---

## 18. 완료 판정 원칙

1. green test는 계약 위반을 고정한 시험이 없는지 확인한 뒤에만 완료 증거가 된다.
2. request builder 존재는 실제 network RPC 배선 증거가 아니다.
3. event table 존재는 상태가 event에서 파생된다는 증거가 아니다.
4. rapid-six synthetic PASS는 과거 incident의 직접 원인 증거가 아니다.
5. 백업 파일 생성은 실제 복구 가능성의 증거가 아니다.
6. branch 이름은 공유 주소가 아니며 exact commit SHA가 필요하다.
7. contract 0.2.0 역사적 인계와 active contract 0.3.0 pin을 섞지 않는다.
8. 실제 원고와 보존 incident는 시험 fixture가 아니다.
9. 양쪽 구현과 server 기준선이 main에서 도달 가능하기 전에는 공유 E2E 완료를 선언하지 않는다.
10. 각 세부 단계는 commit·push·인계표 작성 후 중단한다.
