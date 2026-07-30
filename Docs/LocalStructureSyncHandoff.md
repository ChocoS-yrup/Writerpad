# 10-4 로컬 구조 변경 durable handoff

기준일: 2026-07-26

## 완료 범위

- TXT 생성: full snapshot과 tree-order를 한 `structureChange` batch로 기록한다.
- TXT·폴더 이름 변경/이동: 모든 하위 TXT의 새 path full snapshot과
  tree-order를 한 batch로 기록한다.
- 바인더 재정렬: 파일 변경 없는 로컬 transaction journal을 거쳐
  tree-order를 기록한다.
- 휴지통 이동: 휴지통 path가 아니라 변경 전 live path의 tombstone과
  tree-order를 한 batch로 기록한다.
- 휴지통 복원: 같은 문서 UUID, 새 live path, 확정 본문과 tree-order를
  한 batch로 기록한다.
- 새 권: 25개 빈 TXT snapshot과 tree-order를 한 `volumeCreation` batch로
  기록한다.
- 영구 삭제와 전체 비우기: 서버 row를 직접 삭제하지 않고
  `trash-purge.json` snapshot을 기록한다. 전체 비우기는 한
  `empty_generation`을 추가한다.
- 백업 복원 본문: 일반 저장과 같은 안전한 파일/메타데이터 handoff를
  사용하되 batch 원인을 `backupRestore`로 구분한다.
- Windows 가져오기: import 자체는 로컬 전용이다. 사용자가 서버 UUID를
  확인해 연결한 뒤에만 `ensure_project`, 모든 live TXT, tree-order를 한
  `windowsImport` batch로 기록한다.

## 원자성과 복구

구조 사건은 파일과 메타데이터가 모두 반영되어 journal phase가
`metadata_saved`가 된 뒤에만 durable batch를 만든다. batch와 operation
UUID는 기존 binder journal 안에 저장한 뒤 SQLite에 등록한다. 등록 실패 시
로컬 성공을 rollback하지 않고 journal을 남기며, 다음 구조 명령 전 복구가
같은 UUID와 immutable payload를 재등록한다.

Windows 초기 snapshot은 작품 root의
`.writerpad-windows-import-sync-handoff.json`에 먼저 저장한다. queue 실패 뒤
파일 본문이 바뀌어도 표식의 기존 snapshot을 재생하고, 성공한 뒤에만
표식을 제거한다.

## 숨김 문서 호환

- `__antigravity__/tree-order.json`
- `__antigravity__/trash-purge.json`

숨김 문서 ID는 Windows와 동일하게
`UUIDv5(server_project_id, hidden_path)`로 만든다. 휴지통 항목은
tree-order와 Windows 초기 live snapshot에서 제외한다.

서버에는 folder entity가 없으므로 비어 있는 폴더의 생성·이름·위치는
교차 기기 보존을 보장하지 않는다.

## 10-5 연결

본문 byte preflight, no-op 저장 생략, 초과 크기 UI는 다음 단계에서
`Docs/SyncV2PreflightAndNoOp.md`의 규칙으로 연결했다.
