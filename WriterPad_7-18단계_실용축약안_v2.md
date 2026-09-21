# WriterPad 7~18단계 실용 축약안 v2

작성일: 2026-08-15  
대상: WriterPad 7단계 이후 Windows ↔ GitHub ↔ iPad ↔ Supabase 작업  
전제: 불특정 다수에게 배포하지 않고, 제작자 한 사람이 Windows와 iPad에서 사용하는 집필 프로그램

---

## 0. 결론

기존 18단계를 그대로 계속하는 것은 과하다. 그러나 기존 축약안을 그대로 적용하면
절차뿐 아니라 원고 보호에 필요한 안전장치까지 제거될 수 있다.

이 문서는 다음 원칙으로 다시 작성한 절충안이다.

> 여러 사람이 공개 서비스를 운영하기 때문에 필요한 절차는 줄이고,
> 원고가 사라지거나 두 기기의 상태가 갈라지는 것을 막는 안전장치는 유지한다.

채택할 축약:

- 단계마다 반복하던 긴 인계표와 수동 교차검토 축소
- storage-name 결과 비교를 공유 벡터 자동시험으로 대체
- incident 포렌식을 우선하지 않고 재현시험과 회귀시험을 우선
- 공개 서비스용 production rollout 절차를 개인 배포 절차로 축소
- 증거 커밋은 실제 데이터 손실·원인불명 incident가 있을 때만 생성
- 원격 DB 변경이 없는 로컬 구현에는 매번 별도 승인을 요구하지 않음

유지할 안전장치:

- 정확한 commit SHA로 Windows와 iPad 작업을 인계
- Windows와 iPad가 같은 계약·벡터를 사용한다는 자동시험
- storage-name-v1 유지와 기존 프로젝트 자동 승격 금지
- durable queue, batch/operation ID, payload digest, replay, atomic commit
- 실제 원고가 아닌 합성 staging fixture에서 서버 기능 검증
- 원격 migration·allowlist·프로젝트 승격에는 별도 명시적 승인
- 프로젝트 전체 독립 백업과 실제 복구 시연

---

## 1. 첨부 축약안에서 수정한 핵심 판단

### 1.1 맞는 판단

- Windows에는 5초 polling과 원격 pull 경로가 이미 있다.
- Windows에는 SQLite 기반 durable operation queue가 이미 있다.
- iPad에도 원격 변경 감지 기반이 있다.
- 남은 핵심은 새 동기화 흐름을 발명하는 일이 아니라 이름 정규화, 빠른 구조 변경,
  응답 유실과 재시도에서 상태가 어긋나지 않도록 만드는 일이다.
- storage-name-v2, replay, atomic structure commit은 혼자 쓰는 앱에서도 필요하다.
- 일별 전체 백업과 복구 시연은 기존 절차보다 우선순위가 높다.
- 수동 Windows↔iPad 결과 비교는 공유 벡터 자동시험으로 대체할 수 있다.

### 1.2 그대로 적용하지 않는 판단

#### 실제 원고 프로젝트로 기능시험하지 않는다

백업은 손실 후 복구 수단이지 잘못된 migration, revision, tombstone 또는 폴더 구조
변경을 안전하게 만드는 장치가 아니다. 서버 RPC와 migration은 계속 합성 staging
fixture에서 검증한다.

#### staging과 개인 실사용 DB를 성급하게 합치지 않는다

사용자가 한 명이어도 시험 데이터와 실제 원고의 성격은 다르다. 이미 구축한
`WriterPad Staging`은 합성 검증용으로 유지한다. `ChocoS-yrup's Web`은 WriterPad
개인 실사용 DB라고 확인된 적이 없으므로 임의로 연결하거나 전환하지 않는다.

#### 정확한 commit SHA를 없애지 않는다

브랜치 최신 상태는 바뀐다. Windows 저장소, iPad 저장소, 여러 Codex 창과 시간이
지난 뒤의 작업을 연결하려면 SHA가 가장 값싼 안전장치다. 다만 인계표는 아래의
간단한 형식으로 줄인다.

#### RFC 8785 또는 현재 canonical digest 의미를 단순 sorted JSON으로 바꾸지 않는다

Swift `sortedKeys`와 Python `sort_keys=True`는 숫자 표현, 문자열 escape,
비 ASCII 키 순서에서 같은 bytes를 보장하지 않는다. 구현을 단순화할 수는 있지만
기존 canonical vector와 양쪽 bytes가 같다는 자동시험을 먼저 통과해야 한다.

#### Stage 7을 기존 앱의 수동 저장시험만으로 종료하지 않는다

현재 앱이 새 `document_commit`과 `atomic_structure_commit` RPC를 아직 호출하지
않는다면 기존 앱 저장시험은 새 RPC를 검증하지 못한다. 새 RPC의 최소 server
검증은 한 번 완료해야 한다.

---

## 2. 저장소와 공유 기준

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

두 저장소는 서로 다른 저장소다. 브랜치, worktree, SHA와 파일 경로를 섞지 않는다.

### 실제 공유 단위

```yaml
repository:
base_sha:
result_sha:
changed_paths:
contract_version_or_digest:
tests:
known_limitations:
next_action:
```

규칙:

- 계약을 건드리지 않은 작업은 `contract_version_or_digest: not-applicable`로 적어도 된다.
- 원격 DB 시험이 아니면 `test_run_id`를 만들지 않는다.
- 실제 incident가 아니면 evidence 브랜치를 만들지 않는다.
- 상대 플랫폼은 긴 검토 보고서 대신 exact SHA와 자동시험 결과를 확인한다.
- PR은 복잡하거나 위험한 변경에만 사용한다. 작은 개인 작업에는 push 후 직접 merge도
  가능하지만, merge는 사용자 승인을 받은 뒤 수행한다.

---

## 3. Windows ↔ GitHub ↔ iPad 공통 작업 규칙

다음 공통 블록은 각 단계 프롬프트 앞에 붙여 사용할 수 있다.

### 공통 시작 프롬프트

####여기부터

```text
이번 작업은 혼자 사용하는 WriterPad의 Windows ↔ GitHub ↔ iPad 동기화 작업이다.

저장소를 구분해라.

- iPad·계약·서버:
  https://github.com/ChocoS-yrup/Writerpad
- Windows:
  https://github.com/ChocoS-yrup/WriterPad_main

두 저장소는 서로 다른 저장소다. 경로, 브랜치와 SHA를 섞지 마라.

먼저 Writerpad 최신 origin/main의 다음 문서를 읽어라.

Docs/CrossPlatformSyncGitWorkflow.md

이 문서의 원칙 중 정확한 commit SHA 사용, 사용자 변경 보호, 계약과 구현 분리,
원격 데이터 보호는 유지한다. 다만 이번 개인 프로젝트 축약안에 따라 매 단계의 긴
인계표, 의례적인 상대 플랫폼 수동 검토와 불필요한 evidence commit은 요구하지 않는다.

작업 시작 전에 다음을 짧게 보고해라.

1. 대상 repository와 현재 HEAD 전체 SHA
2. origin/main 전체 SHA
3. working tree 기존 변경 여부
4. 작업 기준 base SHA
5. 적용할 계약 버전·digest 또는 not-applicable
6. 수정할 파일
7. 수정하지 않을 파일과 원격 작업
8. 실행할 자동시험

기존 로컬 변경은 사용자 작업으로 간주해 덮어쓰거나 삭제하지 마라.
dirty 메인 worktree에서 checkout, switch, stash, reset, clean 또는 파일 복원을 하지 마라.
구현이 필요하면 origin/main 또는 지정 base SHA에서 별도의 clean worktree와
`codex/<플랫폼>-<주제>` 브랜치를 만들어라.

검증 후 다음 간단 인계 형식으로 보고해라.

repository:
base_sha:
result_sha:
changed_paths:
contract_version_or_digest:
tests:
known_limitations:
next_action:

브랜치 최신 상태가 아니라 전체 result_sha를 전달해라.
원격 migration, allowlist 변경, 프로젝트 승격, 실제 원고 데이터 변경과 merge는
별도 명시적 승인 없이는 수행하지 마라.
다음 단계를 자동으로 시작하지 마라.
```

####여기까지

### 상대 플랫폼 간이 검토 프롬프트

####여기부터

```text
다음 WriterPad 작업 결과를 exact commit SHA 기준으로 간이 검토해라.

repository: [인계받은 repository]
base_sha: [인계받은 base_sha]
result_sha: [인계받은 전체 result_sha]
changed_paths: [인계받은 changed_paths]
contract_version_or_digest: [인계받은 값]
tests: [인계받은 시험]

브랜치 최신 상태를 검토하지 마라. result_sha의 diff와 파일을 직접 읽어라.

다음만 확인해라.

1. result_sha가 실제 commit인지
2. diff가 선언된 changed_paths와 같은지
3. 공통 계약·벡터를 임의로 바꾸지 않았는지
4. 상대 플랫폼의 아직 병합되지 않은 동작을 가정하지 않는지
5. 선언된 자동시험 결과가 exact SHA 또는 그 synthetic merge에서 성공했는지
6. 원고 손실, 중복 적용 또는 상태 분기 가능성이 새로 생겼는지

코드를 수정하거나 새 단계를 시작하지 마라.
blocking finding이 없으면 PASS와 검토한 전체 SHA만 회신해라.
finding이 있으면 파일·위치·재현 조건과 영향만 간단히 기록해라.
```

####여기까지

### 원격 Supabase 작업 공통 규칙

####여기부터

```text
Supabase 원격 작업은 지정된 project ref 하나에만 수행해라.

WriterPad Staging:
- project_ref: mhpnszcorfzrvhyondxr
- URL: https://mhpnszcorfzrvhyondxr.supabase.co

project ID, 이름과 URL이 모두 일치해야 한다.
다른 프로젝트 목록을 조회하거나 다른 프로젝트 DB에 접속하지 마라.
특히 `ChocoS-yrup's Web`에는 접근하지 마라.

토큰, 비밀번호, connection URI를 출력·로그·파일·shell history·저장소에 남기지 마라.
원격 쓰기 전 read-only preflight를 하고 대상, ledger, allowlist, pending migration과
진행 중 project migration을 보고해라.

승인된 SQL과 정확한 행만 변경해라. 첫 불일치에서 중단하고 기대값을 수정하거나
데이터를 보정하지 마라. 실제 원고 프로젝트로 검증하지 말고 합성 fixture만 사용해라.
```

####여기까지

---

## 4. 현재 확인된 7단계 상태

다음은 2026-08-15 인계 기준이며, 새 작업에서는 반드시 다시 확인한다.

```yaml
server_repository: https://github.com/ChocoS-yrup/Writerpad
server_main_sha: cefb2d890e8e6940744d526dc30e7e110f83188c

contract_version: 0.3.0
contract_git_commit: 2705fcbda0be440a9d82a5e1919f2885c6166727
canonical_contract_sha256: abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c

staging_project_ref: mhpnszcorfzrvhyondxr
allowlist_0_3_0_enabled: false
total_enabled_allowlist_rows: 0
pending_migrations: 0
in_progress_project_migrations: 0

migration_ledger:
  - 20260811000000
  - 20260811010000
  - 20260811020000
  - 20260813063251
  - 20260814182850

harness_path: supabase/tests/stage7_staging_revalidation_harness.sql
harness_sha256: 0935cb3004ef281e7411e0a5f030f22ecef4c467f10e472f066e3e51dce416f7

last_blocker: permission denied to set parameter "plpgsql.variable_conflict"
allowlist_activation: NOT_RUN
harness_execution_count: 0
synthetic_rows_created_by_last_attempt: 0
temporary_cli_role_deleted: true
stage_7: BLOCKED
```

이 차단은 server RPC 실패가 아니라 검증 harness가 비슈퍼유저 역할과 호환되지 않은
문제다. top-level `SET plpgsql.variable_conflict`를 제거하고 각 PL/pgSQL 본문에
`#variable_conflict error`를 적용하는 작은 수정 한 번까지만 진행한다.

---

## 선행단계 - 독립 백업과 복구 가능성 확인

목표: 동기화 결함이 발생해도 원고를 복구할 수 있도록 프로젝트 전체 백업을 확보한다.

####여기부터

```text
WriterPad의 기존 백업 기능을 읽기 전용으로 먼저 감사하고, 개인 원고를 보호하는
독립 백업·복구 절차를 마련해라.

Windows 저장소:
https://github.com/ChocoS-yrup/WriterPad_main

iPad 저장소:
https://github.com/ChocoS-yrup/Writerpad

먼저 다음을 확인해라.

- Windows BackupWorker, RetentionWorker, writing_backup.py
- Windows가 백업하는 파일 종류, 위치, 주기와 보존기간
- iPad LocalBackupStore 및 export 관련 구현
- 현재 백업이 프로젝트 전체 구조, 폴더, 문서, 메타데이터를 포함하는지
- 원본 작업 폴더 손상과 Supabase 손상을 동시에 견딜 수 있는지
- 실제 복구 경로가 시험된 적이 있는지

기존 5분 자동저장 복사본을 프로젝트 전체 독립 백업으로 간주하지 마라.

목표 백업은 다음 조건을 만족해야 한다.

1. 프로젝트 전체를 사람이 읽을 수 있는 txt 또는 Markdown과 manifest로 내보냄
2. 원본 workspace와 다른 로컬 경로에 저장
3. 별도 클라우드 드라이브 등 두 번째 위치에 복제 가능
4. 날짜별 보관, 기본 30일
5. 임시 복구 폴더에서 실제 복구 시연 가능
6. 기존 원고와 원본 프로젝트를 덮어쓰지 않음

먼저 감사 결과와 최소 구현안을 보고해라. 구현이 여러 저장소를 건드리면 Windows와
iPad를 별도 commit으로 나눠라. 실제 원고를 삭제·이동하거나 기존 백업을 정리하지 마라.

완료 조건은 백업 파일 생성 성공이 아니라 임시 위치에서 문서와 폴더 구조를 읽어
복구할 수 있음을 확인하는 것이다.
```

####여기까지

---

## 7단계 - Stage 7 server 검증을 한 번만 마무리

목표: harness 비슈퍼유저 호환성을 작게 수정하고, 한 번의 staging 실행으로 corrective
RPC를 검증한 뒤 Stage 7을 종료한다. harness 자체 문제로 무한히 절차가 늘어나지 않게 한다.

####여기부터

```text
Writerpad Stage 7 재검증 harness의 non-superuser 호환성을 수정하고 검증해라.

repository:
https://github.com/ChocoS-yrup/Writerpad

base_main_sha:
cefb2d890e8e6940744d526dc30e7e110f83188c

branch:
codex/server-stage7-nonsuperuser-harness

현재 사용자 worktree를 변경하지 말고 clean worktree를 사용해라.

허용 파일:

- supabase/tests/stage7_revalidation_fingerprint_helpers.sql
- supabase/tests/stage7_staging_revalidation_harness.sql
- non-superuser 회귀시험용 파일 1개
- 필요한 경우 해당 시험의 최소 workflow 변경

구현:

- top-level/session-level `SET plpgsql.variable_conflict` 의존을 제거
- 필요한 각 PL/pgSQL 함수 또는 DO block 본문 시작에
  `#variable_conflict error` 적용
- directive는 dollar-quoted PL/pgSQL 본문 내부에서 DECLARE/BEGIN보다 앞에 배치
- fingerprint 계산, psql meta-command, include 순서와 functional assertion은 변경 금지

검증:

- PostgreSQL 17.6
- 관리자 역할
- 비슈퍼유저이며 해당 SET 권한이 없는 역할
- 수정된 helper와 harness의 compile/execute 가능성
- 의도적인 ambiguous reference가 계속 오류인지
- 기존 fingerprint 규약 불변
- git diff --check
- 새 helper와 harness SHA-256

production RPC, contract, migration과 allowlist는 변경하지 마라.
검증이 통과하면 commit·push하고 exact result SHA와 CI 결과를 보고해라.

이번 개인 축약 절차에서는 별도 Windows 수동 재실행을 필수로 하지 않는다.
대신 GitHub exact-head CI와 diff 간이 검토만 통과하면 된다.

원격 Stage 7 실행은 자동으로 시작하지 마라. 새 SHA와 새 실행 식별자를 제시하고
별도 원격 실행 승인을 받아라.

승인 후에는 WriterPad Staging에서 exact harness를 수정 없이 한 번만 실행해라.
PASS면 allowlist를 다시 false로 유지하고 Stage 7을 종료해라.

다음 실행에서도 functional assertion 전에 또 harness 도구·권한 문제가 발생하면
exact harness 수정을 반복하지 말고 중단해라. 그때는 두 corrective RPC의
AUTH_REQUIRED/FORBIDDEN JSON envelope, authorized success와 rollback만 검증하는
작은 non-superuser smoke test로 교체하는 안을 보고해라.
```

####여기까지

---

## 8단계 - Windows storage-name-v2 구현

목표: Windows가 Unicode 정규화 차이로 같은 이름을 다른 저장 경로로 취급하지 않도록
storage-name-v2를 구현한다.

####여기부터

```text
Windows WriterPad에 storage-name-v2 클라이언트 구현을 추가해라.

Windows repository:
https://github.com/ChocoS-yrup/WriterPad_main

계약 repository:
https://github.com/ChocoS-yrup/Writerpad

계약 기준:
- contract_version: 0.3.0
- contract_git_commit: 2705fcbda0be440a9d82a5e1919f2885c6166727
- canonical_contract_sha256:
  abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c

Windows 메인 worktree에는 사용자 변경과 빌드 산출물이 많으므로 그곳에서 checkout,
stash, reset, clean 또는 파일 복원을 하지 마라. 최신 origin/main에서 별도 clean
worktree와 `codex/windows-storage-name-v2` 브랜치를 만들어라.

먼저 계약의 storage-name-v2 schema, Unicode 동결 자산과 conformance vector를 읽어라.

구현 요구:

- Unicode 15 NFKC와 동결 casefold 자산 사용
- pre-NFKC supplementary adjacency 거부
- post-NFKC separator 거부
- defensive post-NFKC baseline 재검사
- 계약의 검사 순서와 오류 코드 유지
- storage-name-v1 제거 금지
- 기존 LEGACY 프로젝트 동작 변경 금지
- contract pin을 임의로 교체하지 않음

시험:

- canonical storage-name-v2 conformance vector 전량
- SN-001..SN-029
- Cherokee, Cyrillic, U+0130, Straße
- NFC/NFD 한글 이름 수렴
- supplementary adjacency
- post-NFKC separator
- v1 회귀시험
- 패키징된 Windows 실행 환경의 Unicode 15 확인

새 기대값을 코드 결과에 맞춰 바꾸지 마라. 불일치하면 첫 vector와 양쪽 bytes를
기록하고 중단해라.

원격 Supabase, iPad 코드, contract와 migration은 수정하지 마라.
검증 후 하나의 의도적인 commit으로 push하고 간단 인계 형식으로 전체 SHA를 보고해라.
다음 단계를 자동으로 시작하지 마라.
```

####여기까지

---

## 9단계 - iPad storage-name-v2 구현

목표: iPad가 Windows와 동일한 Unicode 15 동결 규칙과 결과 bytes를 사용하게 한다.

####여기부터

```text
iPad WriterPad에 storage-name-v2 클라이언트 구현을 추가해라.

repository:
https://github.com/ChocoS-yrup/Writerpad

Windows counterpart commit:
[8단계 완료 보고의 Windows 전체 result_sha]

계약 기준:
- contract_version: 0.3.0
- contract_git_commit: 2705fcbda0be440a9d82a5e1919f2885c6166727
- canonical_contract_sha256:
  abbd234c7b65d422c2e43d468f4f724e069ede26a3d24be22eb8b35cce8ebf2c

최신 origin/main에서 clean worktree와 `codex/ipad-storage-name-v2` 브랜치를 만들어라.
Windows 저장소는 8단계 exact commit의 결과와 vector output을 읽는 용도로만 사용하고
수정하지 마라.

구현 요구:

- 계약에 고정된 Unicode baseline, exclusion과 casefold 자산을 Swift 배포물에 포함
- Foundation 런타임 버전에 따라 결과가 바뀌지 않도록 동결 자료 사용
- pre-NFKC supplementary adjacency 거부
- post-NFKC separator 거부
- defensive post-NFKC baseline 재검사
- storage-name-v1 유지
- 기존 프로젝트 자동 승격 금지
- Xcode target의 compile source/resource 등록 확인

시험:

- canonical storage-name-v2 vector 전량
- SN-001..SN-029
- Windows exact commit과 대표 UTF-8 bytes 일치
- NFC/NFD 한글 수렴
- Cherokee/Cyrillic 경계값
- X+U+FF9E, X+U+FF9F 상위면 표본
- 기존 v1 회귀
- clean Xcode build와 XCTest

Windows 결과를 수동으로 복사해 기대값을 만들지 말고 계약 vector를 공통 source로 사용해라.
원격 Supabase, server migration과 Windows 코드는 수정하지 마라.

검증 후 commit·push하고 전체 result SHA를 간단 인계 형식으로 보고해라.
다음 단계를 자동으로 시작하지 마라.
```

####여기까지

---

## 10단계 - 공유 storage-name 벡터 자동화

목표: 기존 수동 Windows→iPad 교차검토를 공통 vector 기반 자동시험으로 대체한다.

####여기부터

```text
Windows와 iPad storage-name-v2 구현이 동일한 canonical vector를 직접 읽어 검증하도록
공유시험을 정리해라.

계약 repository:
https://github.com/ChocoS-yrup/Writerpad

먼저 기존 다음 파일이 목적을 충족하는지 확인해라.

sync-contract/conformance_vectors/storage-name-v2.json

기존 canonical vector가 충분하면 새 `storage_name_v2_cases.json`을 중복 생성하지 마라.
부족한 항목이 있다면 계약 의미를 바꾸지 않는 범위에서 vector를 보완하고 계약 검증을
실행해라. 계약 의미나 결과가 바뀌는 수정은 별도 계약 변경으로 분리하고 중단해라.

Windows와 iPad 시험은 다음을 증명해야 한다.

- 같은 vector 파일 또는 같은 exact bytes를 사용
- vector 파일 SHA-256 기록
- 각 id의 accept/reject, error code와 UTF-8 결과 일치
- vector 누락 또는 미등록 resource가 있으면 실패
- 양쪽 결과 요약 digest 일치

8단계 Windows result SHA와 9단계 iPad result SHA를 정확히 사용해라.
사람이 출력 표를 눈으로 비교하는 장문의 검토 문서는 만들지 마라.

각 저장소 변경이 필요하면 별도 commit으로 만들고 다음만 보고해라.

- Windows result SHA
- iPad result SHA
- vector SHA-256
- Windows test result
- iPad test result
- 첫 불일치 또는 PASS

원격 Supabase와 production 데이터는 건드리지 마라.
```

####여기까지

---

## 11단계 - storage-name-v2 통합 및 merge gate

목표: 수동 교차검토 의식 대신 exact SHA와 자동시험을 확인하고 양쪽 구현을 main에 통합한다.

####여기부터

```text
storage-name-v2 Windows와 iPad 구현의 merge 준비 상태를 읽기 전용으로 판정해라.

Windows repository:
https://github.com/ChocoS-yrup/WriterPad_main

Windows result SHA:
[10단계에서 확정한 전체 SHA]

iPad repository:
https://github.com/ChocoS-yrup/Writerpad

iPad result SHA:
[10단계에서 확정한 전체 SHA]

shared vector SHA-256:
[10단계에서 확정한 SHA-256]

다음을 확인해라.

1. 두 result SHA가 실제 commit이며 해당 repository에서 도달 가능한가
2. 두 구현이 같은 contract 0.3.0과 vector bytes를 사용하는가
3. 양쪽 storage-name-v2 시험이 모두 PASS인가
4. storage-name-v1 회귀시험이 PASS인가
5. Xcode resource 등록과 Windows 패키징 자산이 포함됐는가
6. 기존 프로젝트를 자동 승격하는 코드가 없는가
7. 원격 DB 변경이 diff에 섞이지 않았는가

blocking finding이 없으면 MERGE_READY로 보고해라.
장문의 상대 플랫폼 수동 재구현 검토는 하지 마라.

사용자의 명시적 merge 승인 전에는 merge하지 마라.
승인을 받으면 양쪽 repository를 각각 병합하고 실제 merge SHA와 최신 origin/main SHA를
보고한 뒤 중단해라.
```

####여기까지

---

## 12단계 - 빠른 이름변경 6회 재현과 회귀시험

목표: 과거 마지막 세 이름변경이 대기에 남은 사건을 현재 코드에서 재현하고,
재현 가능 여부와 관계없이 자동 회귀시험을 만든다.

####여기부터

```text
WriterPad에서 같은 폴더 이름을 빠르게 6번 연속 변경하는 사건을 재현하고 회귀시험을 추가해라.

대상:

- Windows repository: https://github.com/ChocoS-yrup/WriterPad_main
- iPad repository: https://github.com/ChocoS-yrup/Writerpad
- remote test target: WriterPad Staging의 새 합성 프로젝트만

실제 원고 프로젝트와 기존 보존 fixture를 변경하지 마라.
기존 incident 증거는 읽기 전용으로 참고할 수 있지만, 긴 포렌식 보고서와 evidence
브랜치를 완료 조건으로 삼지 마라.

순서:

1. 현재 양쪽 main SHA와 앱 build를 기록
2. 새 합성 프로젝트와 새 실행 ID 준비
3. 같은 폴더에 대해 이름을 6번 빠르게 변경
4. 각 intent의 operation ID, sequence, queue status와 최종 server 이름 확인
5. 앱 재시작 전후 pending queue 확인
6. 반대 기기가 최종 이름과 구조 revision으로 수렴하는지 확인

재현되면:

- 재현을 고정하는 실패 시험을 먼저 추가
- 원인을 queue coalescing, sequence gap, revision conflict, retry 또는 pull apply로 분류
- 해당 원인만 최소 수정
- 6건 모두 terminal 상태가 되고 최종 이름이 일치하는 시험을 통과

재현되지 않으면:

- 재현 명령, 속도와 관찰값을 기록
- 6개 연속 sequence, restart recovery와 final convergence 회귀시험은 추가
- 원인이 확인되지 않았다는 이유만으로 15단계를 영구 차단하지 않음

기대값 변경, 기존 fixture 삭제, 실제 원고 이름 변경과 자동 프로젝트 승격은 금지한다.
플랫폼별 수정은 별도 commit으로 만들고 exact SHA를 보고해라.
```

####여기까지

---

## 13단계 - protocol 3 전송 기반과 재시도 안전성

목표: 오프라인·응답 유실·앱 재시작에서도 동일 작업이 중복되거나 사라지지 않게 한다.

####여기부터

```text
WriterPad protocol 3 전송 기반을 Windows와 iPad에 구현해라.

이 단계에서 유지해야 하는 핵심:

- durable queue
- batch_id와 operation_id
- payload digest
- exact replay
- response-loss replay
- 앱 재시작 후 queue recovery
- append-only attempt/event에서 terminal 상태 파생
- 같은 ID와 다른 payload의 명시적 거부

canonical JSON 의미를 단순 `sortedKeys` 또는 `sort_keys=True`로 임의 교체하지 마라.
구현을 단순화하려면 현재 계약 vector의 canonical bytes와 양쪽 digest가 전량 동일함을
먼저 증명해라. 숫자, Unicode key, escape와 nested object 경계값을 포함해라.

UI에 표시하는 오류 분류는 다음 세 종류로 단순화할 수 있다.

- 자동 재시도 가능
- 자동 재시도 불가
- 사용자 개입 필요

그러나 server의 구체적인 error code와 진단 로그는 삭제하지 마라.

플랫폼별 clean worktree와 별도 commit을 사용해라. 서버 계약을 바꿔야 한다면
클라이언트 구현과 섞지 말고 먼저 별도 contract/server 변경으로 보고하고 중단해라.

필수 시험:

- response 유실 후 같은 batch replay
- 같은 ID와 다른 payload
- offline 작성 후 online 전환
- 앱 강제 종료 후 queue 복구
- sequence gap
- transient 오류 backoff
- terminal 실패가 무한 재시도되지 않음
- 양쪽 canonical payload digest 일치

실제 원고와 원격 allowlist는 변경하지 마라.
각 플랫폼 result SHA와 공통 digest 시험 결과를 보고한 뒤 중단해라.
```

####여기까지

---

## 14단계 - document_commit 실제 배선

목표: 문서 본문 쓰기를 새 idempotent RPC에 연결하고 원고 손실과 중복 적용을 막는다.

####여기부터

```text
Windows와 iPad의 문서 저장 경로를 canonical `document_commit` RPC에 연결해라.

현재 실제 네트워크 호출이 legacy `commit_document`라면 먼저 호출 지점과 queue 작업
종류 이름을 구분해서 보고해라. 로컬 enum의 `document_commit` 문자열을 실제 RPC
호출 증거로 간주하지 마라.

구현 요구:

- protocol 3에서 검증된 batch/operation metadata 사용
- 빈 본문을 유효한 저장으로 처리
- content digest와 UTF-8 byte count 일치
- revision conflict 처리
- exact replay와 response-loss replay
- document update가 name, parent_folder_id와 structure_revision을 변경하지 못함
- successful server result 이후에만 queue terminal 처리
- 앱 재시작 후 inflight 상태 복구
- 기존 v1/legacy 프로젝트는 기존 경로 유지

Windows와 iPad는 별도 commit으로 구현하고 같은 contract vector를 사용해라.

필수 시험:

- 생성, 수정, 빈 본문, 삭제·복원 경계
- stale revision
- 응답 유실 후 replay
- 같은 operation ID와 다른 content 거부
- 문서 저장이 구조 필드를 바꾸지 않음
- offline queue와 restart recovery

로컬 자동시험과 합성 staging 시험을 구분해 보고해라.
원격 시험은 별도 승인 후 합성 프로젝트에서만 수행해라.
실제 원고 프로젝트, migration, contract와 allowlist를 임의로 변경하지 마라.
```

####여기까지

---

## 15단계 - atomic_structure_commit 실제 배선

목표: 폴더 생성·이름변경·이동·삭제와 tree order를 부분 적용 없이 원자적으로 반영한다.

####여기부터

```text
Windows와 iPad의 구조 변경 경로를 canonical `atomic_structure_commit` RPC에 연결해라.

핵심 요구:

- batch 내부 sequence는 1부터 연속
- 전체 성공 또는 전체 rollback
- 부분 적용 금지
- exact replay
- response-loss replay
- 같은 batch ID와 다른 payload 거부
- revision과 structure_revision 정합
- 앱 재시작 후 pending structure queue 복구
- 빠른 이름변경 6건이 모두 terminal 상태에 도달
- 반대 기기가 최종 구조와 tree order로 수렴
- 기존 LEGACY 프로젝트와 storage-name-v1 경로 보존

12단계 incident의 직접 원인이 완전히 증명되지 않았다는 이유만으로 이 구현을 막지 마라.
대신 12단계에서 만든 rapid-six-renames 회귀시험을 필수 gate로 사용해라.

필수 시험:

- 폴더 생성·이름변경·이동·삭제
- 같은 이름의 다른 folder ID
- folder와 document를 함께 만드는 batch
- 중간 intent 실패 시 전체 rollback
- response 유실 후 exact replay
- changed-payload ID reuse
- 빠른 이름변경 6회
- 앱 종료·재시작 후 queue 복구
- 양쪽 pending count가 0으로 수렴

Windows와 iPad 구현을 별도 commit으로 만들고 exact SHA를 보고해라.
원격 staging 시험은 별도 승인과 합성 fixture로만 실행해라.
기존 원고, incident fixture와 프로젝트 mode를 변경하지 마라.
```

####여기까지

---

## 16단계 - 합성 staging 종단간 검증

목표: 증거 보고서를 만드는 대신 실제 사용 시나리오가 양쪽에서 수렴하는지 확인한다.

####여기부터

```text
WriterPad Staging에서 Windows와 iPad의 종단간 동기화를 합성 fixture로 검증해라.

대상:

- project_ref: mhpnszcorfzrvhyondxr
- 실제 원고가 아닌 새 합성 사용자·프로젝트
- Windows와 iPad의 병합된 exact main SHA
- contract_version 0.3.0의 정확한 allowlist 행

원격 쓰기 전에 다음을 read-only로 확인하고 보고해라.

- project identity
- migration ledger와 pending migration 0
- 진행 중 project migration 0
- contract allowlist의 정확한 행
- 실행할 양쪽 build SHA
- 새 합성 ID가 미사용인지

allowlist 활성화가 필요하면 정확한 0.3.0 행 하나만 변경하도록 별도 승인을 받아라.

자동시험과 약 30분의 실사용 체크리스트를 실행해라.

- Windows 문서 생성 → iPad 반영
- iPad 문서 수정 → 5초 안에 Windows 반영
- 한글 NFC/NFD 이름이 하나로 수렴
- 거부 이름이 양쪽에서 동일하게 거부
- 문서 생성·수정·삭제·복원
- 폴더 이름 6회 연속 변경
- 비행기모드 또는 강제 offline → 작성 → online 복귀
- 응답 유실 replay
- 앱 강제 종료 → 재실행 → queue 복구
- 같은 문서의 근접 동시 수정에서 한쪽 내용이 조용히 사라지지 않음
- 양쪽 pending count 0
- server structure와 양쪽 local structure 일치

첫 불일치에서 중단하고 기대값을 바꾸거나 fixture를 정리하지 마라.

장문의 evidence commit은 만들지 않는다. 대신 다음만 보고해라.

- Windows main SHA와 build SHA
- iPad main SHA와 build SHA
- contract version/digest
- 합성 project ID
- 체크리스트 PASS/FAIL
- 첫 불일치
- 실행 후 pending count와 allowlist 상태

PASS해도 실제 원고 프로젝트를 자동 승격하거나 다음 단계를 자동 시작하지 마라.
```

####여기까지

---

## 17단계 - 개인 배포 준비와 복구 게이트

목표: 공개 production 준비 대신 실제 원고를 넣기 전에 백업과 되돌리기 수단을 확인한다.

####여기부터

```text
WriterPad를 개인 실사용으로 전환하기 위한 준비 상태를 읽기 전용으로 판정해라.

이 앱은 불특정 다수에게 배포하지 않는다. 공개 서비스용 트래픽, 다수 구형 클라이언트,
조직 승인과 점진적 사용자 rollout은 검토하지 않는다.

대신 다음을 확인해라.

1. Windows 프로젝트 전체 백업이 독립 위치에 존재
2. iPad에서 원고 export 또는 복구 가능한 사본 존재
3. 임시 폴더에서 실제 복구 시연 PASS
4. Windows와 iPad exact release SHA 및 build ID 확인
5. Stage 16 합성 E2E PASS
6. storage-name-v1과 legacy 경로 유지
7. 기존 프로젝트 자동 승격 코드 없음
8. 실패 시 되돌릴 client build 확보
9. allowlist를 false로 되돌리는 정확한 SQL 또는 절차 준비
10. Supabase Free plan에 PITR이 없다는 제한 기록

개인 실사용 DB를 WriterPad Staging과 합칠지 자동 결정하지 마라.
`ChocoS-yrup's Web`을 WriterPad DB로 간주하거나 접근하지 마라.

실사용 DB가 아직 결정되지 않았다면 `not-verified`로 보고하고 사용자 결정을 요청해라.
DB를 새로 만들거나 기존 프로젝트를 재사용하는 것은 별도 승인 대상이다.

이번 단계에서는 migration, allowlist, 프로젝트 승격, 실제 원고 업로드와 client 설치를
수행하지 마라.

결과는 READY 또는 BLOCKED로 보고하고 다음 개인 배포 단계에서 필요한 정확한 승인
범위를 작성해라.
```

####여기까지

---

## 18단계 - 개인 실사용 활성화와 관찰

목표: 공개 rollout 대신 한 사람의 두 기기를 정확한 build로 활성화하고 즉시 복구 가능한
상태에서 관찰한다.

####여기부터

```text
사용자가 명시적으로 승인한 경우에만 WriterPad 개인 실사용 활성화를 진행해라.

승인에는 다음 값이 모두 포함돼야 한다.

- 정확한 Supabase project ref
- Windows release commit SHA와 build SHA-256
- iPad release commit SHA와 build ID
- contract version과 canonical digest
- 적용할 migration 또는 pending 0 확인
- 활성화할 allowlist의 정확한 행
- 실사용으로 연결할 프로젝트

실행 전 전체 백업과 복구 시연 결과를 다시 확인해라.

활성화 순서:

1. 대상 DB identity와 ledger read-only 확인
2. 정확한 allowlist 행만 guarded 방식으로 활성화
3. Windows와 iPad에 승인된 exact build 설치
4. 새 빈 개인 프로젝트 또는 사용자가 지정한 한 프로젝트만 연결
5. 기존 프로젝트는 LEGACY/기존 epoch 상태를 유지
6. 자동 승격 금지
7. 짧은 문서와 폴더로 양방향 저장 확인
8. queue pending 0과 server/local 수렴 확인
9. 일정 시간 관찰 후 실제 원고 사용 여부를 사용자에게 보고

문제가 생기면:

- 신규 쓰기를 중단
- 정확한 allowlist 행을 false로 되돌릴지 사용자에게 보고
- 이전 client build로 되돌림
- 백업에서 새 별도 위치로 복구
- 실패 데이터를 임의로 삭제·재분류하지 않음

공개 배포, 다른 사용자 초대, 다른 Supabase 프로젝트 접근, 기존 프로젝트 일괄 승격과
다음 계약 개정을 자동으로 시작하지 마라.

완료 보고:

repository_and_commit_shas:
client_builds:
server_project_ref:
contract_version_or_digest:
allowlist_final_state:
connected_project:
backup_and_restore_status:
smoke_test_results:
pending_queue_counts:
known_limitations:
next_action:
```

####여기까지

---

## 5. 축약 후 실제 로드맵

```text
[선행] 독립 백업 + 실제 복구 시연
   ↓
[7] server harness 권한 수정 1회 + staging 검증 1회
   ↓
[8] Windows storage-name-v2
   ↓
[9] iPad storage-name-v2
   ↓
[10~11] 공유 vector 자동시험 + 양쪽 merge
   ↓
[12] 빠른 이름변경 6회 재현·회귀
   ↓
[13] durable queue + digest + replay
   ↓
[14] document_commit 배선
   ↓
[15] atomic_structure_commit 배선
   ↓
[16] 합성 staging E2E
   ↓
[17~18] 백업·rollback 확인 후 개인 실사용 활성화
```

원래 12개 단계 번호는 추적을 위해 유지했지만 실제 운영 단위는 다음 6개 묶음이다.

1. 백업·복구
2. server 검증 마무리
3. 양쪽 storage-name-v2
4. 빠른 이름변경 회귀
5. protocol 3과 두 commit RPC 배선
6. 합성 E2E와 개인 배포

---

## 6. 앞으로 승인을 요구할 작업

다음 작업에만 별도 명시적 승인을 요구한다.

- Supabase 원격 migration 적용
- allowlist enabled/revoked 변경
- 원격 합성 fixture 생성 또는 변경
- 실제 원고 DB 연결
- 기존 프로젝트 mode/epoch/digest 변경 또는 승격
- 실제 원고 업로드·삭제·이름 일괄변경
- PR merge 또는 release 배포
- 임시 DB 역할 또는 자격증명 발급
- 백업 삭제와 보존기간 정리

다음 작업은 범위가 명확하면 별도 승인 없이 진행할 수 있다.

- read-only 코드·diff·CI 확인
- clean worktree 생성
- 허용된 파일의 로컬 구현
- 로컬 자동시험
- 의도적인 commit과 branch push
- 공통 vector 기반 양쪽 결과 비교

---

## 7. 마지막 원칙

1. 원고 보호는 절차 문서보다 백업·replay·atomicity로 달성한다.
2. 혼자 쓰더라도 Windows와 iPad는 서로 다른 클라이언트이므로 데이터 정합성 계약은 유지한다.
3. exact SHA는 관료주의가 아니라 여러 기기와 여러 Codex 창 사이의 주소다.
4. 실제 원고는 시험 fixture가 아니다.
5. 자동시험으로 대체할 수 있는 수동 검토는 제거한다.
6. harness를 검증하기 위한 harness가 반복해서 생기면 작은 targeted smoke test로 줄인다.
7. 새 기능보다 독립 백업과 복구 시연을 먼저 완료한다.

