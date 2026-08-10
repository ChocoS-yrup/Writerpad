# Windows–iPad Sync Git Workflow

이 문서는 Windows, iPad, 서버가 같은 Sync 계약과 사건을 기준으로 작업하기
위한 GitHub 운영 규칙이다. GitHub의 `main`은 양쪽에서 검증된 공통 기준선이며,
실행 중인 앱이나 로컬 작업 폴더를 실시간으로 공유하는 공간이 아니다.

## 1. 기준선과 브랜치

- `main`: 양쪽 검토와 필수 검증을 통과한 공통 기준선
- `codex/contract-<주제>`: 계약·스키마·공통 테스트 벡터 변경
- `codex/ipad-<사건 또는 기능>`: iPad 구현과 iPad 전용 테스트
- `codex/windows-<사건 또는 기능>`: Windows 구현과 Windows 전용 테스트
- `codex/incident-<test_run_id>`: 코드 변경 없는 증거 정규화가 필요한 경우

플랫폼별 장기 브랜치를 계속 재사용하지 않는다. 각 단계는 최신 `origin/main`에서
새 브랜치를 만들며, 하나의 브랜치에는 하나의 판정 가능한 목적만 둔다.

```bash
git fetch origin
git switch -c codex/ipad-<주제> origin/main
```

Windows에서도 Git Bash, PowerShell, 터미널에서 같은 Git 명령을 사용할 수 있다.
Python 실행 명령은 플랫폼별로 다를 수 있으므로 Windows에서는 `py -3.12` 또는
`python`을 사용하고, Microsoft Store alias일 수 있는 `python3`에 의존하지 않는다.

## 2. 단계별 완료 조건

한 단계는 다음 순서를 모두 마쳐야 완료된다.

1. 작업 시작 전에 `origin/main`과 지정된 계약 커밋을 fetch한다.
2. 작업 프롬프트에 변경 허용 범위와 금지 범위를 기록한다.
3. 허용된 파일만 수정하고 관련 검증을 실행한다.
4. 결과를 하나 이상의 의도적인 커밋으로 남긴다.
5. 브랜치를 push하고 아래 인계표를 상대 플랫폼에 전달한다.
6. 상대 플랫폼은 브랜치 이름이 아니라 정확한 커밋 SHA를 checkout해 읽는다.
7. 상대 플랫폼이 계약·영향 범위·테스트 결과를 확인한다.
8. PR로 `main`에 병합한 후에만 다음 공통 단계를 시작한다.

미커밋 파일, 작업자의 로컬 DB, 최신이라는 설명만으로는 단계를 인계할 수 없다.
공유 종단간 테스트에는 양쪽 구현 커밋이 모두 `main`에서 도달 가능해야 한다.

## 3. 필수 인계표

각 단계가 끝나면 다음 블록을 그대로 채워 전달한다.

```text
handoff_version: 1
stage_id:
platform: ipad | windows | contract | server | evidence
repository: https://github.com/ChocoS-yrup/Writerpad
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
```

해당하지 않는 필드는 지우지 말고 `not-applicable`로 기록한다. 사건 분석에서는
`test_run_id`와 `server_project_id`를 반드시 기입한다. 앱 코드만 검토하는 경우에도
사용한 계약 버전·커밋·canonical SHA를 기록한다.

## 4. 상대 플랫폼 검토 절차

인계받은 쪽은 다음 순서로 검토한다.

```bash
git fetch origin
git show --stat <commit_sha>
git diff <base_main_sha>..<commit_sha> --
git switch --detach <commit_sha>
git rev-parse HEAD
```

Windows PowerShell에서는 저장소 밖의 임시 가상환경으로 다음과 같이 검증한다.

```powershell
$contractEnv = Join-Path $env:TEMP "writerpad-contract-review"
py -3.12 -m venv $contractEnv
& "$contractEnv\Scripts\python.exe" -m pip install -r sync-contract\requirements-validation.txt
& "$contractEnv\Scripts\python.exe" sync-contract\scripts\verify_contract.py
```

macOS/Linux에서는 다음과 같이 실행한다.

```bash
contract_env="${TMPDIR:-/tmp}/writerpad-contract-review"
python3 -m venv "$contract_env"
"$contract_env/bin/python" -m pip install -r sync-contract/requirements-validation.txt
"$contract_env/bin/python" sync-contract/scripts/verify_contract.py
```

검토자는 다음을 확인한다.

- 전달받은 커밋과 실제 checkout의 `HEAD`가 같은가
- `protocol.json`의 canonical SHA가 lock과 같은가
- 변경 파일이 선언된 범위와 같은가
- 다른 플랫폼의 미완료 동작을 가정하지 않는가
- 같은 `server_project_id`와 `test_run_id`의 증거를 보는가
- 삭제, rename, tombstone, revision 충돌 의미가 계약과 같은가

검토가 끝난 뒤 원래 작업 브랜치로 돌아간다. detached HEAD에서 구현 커밋을 만들지
않는다.

GitHub Actions는 모든 PR에서 다음 검증을 서로 다른 check로 실행한다.

- PR head의 정확한 SHA: Ubuntu와 Windows에서 각각 검증
- `main`과 PR head의 합성 merge SHA: Ubuntu에서 통합 검증

각 check는 예상 SHA와 실제 `git rev-parse HEAD`를 로그에 남기고 다르면 실패한다.
따라서 merge-result 성공을 exact-head 검토로 대신하거나 그 반대로 대신하지 않는다.
Windows/iPad 코드만 바뀐 Sync PR도 공통 계약 검증을 생략하지 않는다.

## 5. 계약 변경 규칙

계약 변경은 앱 구현과 분리된 `codex/contract-*` 브랜치에서 먼저 진행한다.

1. `protocol.json`, 관련 schema, test vector를 함께 수정한다.
2. `contract_version`과 `CHANGELOG.md`를 갱신한다.
3. `contract-lock.json`의 canonical SHA와 byte length를 갱신한다.
4. 공통 검증기를 통과시킨다.
5. Windows와 iPad가 같은 계약 커밋을 검토한다.
6. 계약 PR을 먼저 병합하고 양쪽 구현은 그 병합 커밋에서 분기한다.

서버 allowlist에 추가되기 전 계약은 초안이다. 클라이언트가 capability를 선언했다고
해서 서버가 구조 변경을 허용한 것으로 간주하지 않는다.

## 6. Incident와 구현의 분리

- 재현 중인 원본 DB, snapshot, 로그는 먼저 읽기 전용으로 보존한다.
- 증거 보존 단계와 코드 수정 단계를 같은 커밋이나 PR에 섞지 않는다.
- `ensure_project`, 초기 tree 병합 등 다른 사건을 하나의 수정으로 묶지 않는다.
- incident에는 양쪽 commit, build, contract, project, revision을 기록한다.
- 민감한 원본 DB나 사용자 문서는 공개 저장소에 push하지 않는다. 공개 가능한
  정규화 JSON도 식별정보 제거 여부를 확인한다.

## 7. 커밋과 PR 원칙

- 커밋 메시지는 결과가 아니라 변경 의도를 설명한다.
- 자동 생성물이나 무관한 로컬 변경을 함께 stage하지 않는다.
- force-push가 필요한 공유 브랜치 재작성은 피한다.
- PR 템플릿의 계약·사건 식별 필드를 채운다.
- 상대 플랫폼 검토가 끝나지 않았으면 PR을 draft로 유지한다.
- 병합 후 다음 담당자는 반드시 새 `origin/main`에서 시작한다.

## 8. 권장 단계 프롬프트

```text
먼저 git fetch origin을 실행하고 지정된 base_main_sha와
contract_git_commit을 확인해줘. 이번 단계의 허용 파일만 수정하고,
검증 후 별도 브랜치에 커밋·push해줘. 완료 보고에는 필수 인계표를
채우고 정확한 commit_sha를 포함해줘. 다음 단계의 구현은 시작하지 마.
```
