# 10-3 LocalDocumentStore·저장 세션 연결

## 저장 순서

편집기에서 확정한 하나의 immutable full snapshot은 다음 순서로 처리한다.

1. `EditorSessionModel`이 본문·커서·save generation을 함께 캡처한다.
2. `LocalDocumentStore`가 UTF-8 TXT를 원자 교체한다.
3. 같은 바이트로 SHA-256을 계산하고 SwiftData 파일 메타데이터를 갱신한다.
4. 연결된 작품이면 문서별 handoff marker를 먼저 원자 기록한 뒤
   `SyncV2Store.enqueue(_:)`에 같은 snapshot을 전달한다.
5. 로컬 저장 상태와 queue handoff 상태를 분리해 UI를 갱신한다.

`savedContent`는 다시 디스크에서 읽지 않고 TXT 저장에 사용한 바이트를 재사용한다.
따라서 뒤따르는 저장·이름 변경과 경합해 다른 본문이 operation payload가 되는
경로가 없다.

## 순서와 재실행 복구

`LocalDocumentStore` actor 하나가 동일 document UUID의 좌우 pane 저장을 같은
save tail과 pending handoff 배열에 직렬화한다. SQLite는 같은 document UUID에
단일 sequence lane을 발급한다. save generation은 실행 중 stale 제출을 거르는
용도이며 operation identity로 쓰지 않는다.

연결된 작품의 enqueue 전에는 작품 폴더에 다음 marker를 둔다.

```text
.writerpad-sync-handoff-<document-uuid>.json
```

marker에는 순서가 보존된 batch 배열과 immutable 본문·해시·batch ID·operation
ID가 들어간다. enqueue 실패 시 marker와 메모리 배열을 유지한다. 사용자가
재시도하거나 다음 저장을 하면 앞 batch부터 기록한다. 앱을 다시 실행해도 marker를
읽어 같은 ID로 재생하므로 SQLite의 batch replay가 중복 row 없이 복구한다.
enqueue 성공 뒤 marker 삭제가 실패해도 재생은 멱등이다.

연결되지 않은 local-only 작품은 marker나 queue를 만들지 않아 기존 로컬 저장
경로를 유지한다.

## IME와 UI

marked text가 남아 있는 동안 `saveNow`는 실제 저장과 enqueue를 보류한다. 조합
확정 뒤 하나의 snapshot만 저장한다.

- 로컬 저장과 enqueue 성공: `로컬 저장됨 · 동기화 대기`
- 로컬 저장 성공, enqueue 실패: `로컬 저장됨 · 동기화 기록 실패`
- queue 실패 배지는 재시도 동작과 VoiceOver hint를 제공한다.
- queue 실패는 로컬 저장 성공을 되돌리거나 문서 전환을 막지 않는다.
- 새 로컬 저장이 성공해도 앞선 실패 batch를 먼저 재시도하므로 경고가 조용히
  사라지지 않는다.

## 자동 검증

- TXT→metadata→queue 호출 순서
- immutable snapshot의 본문·해시·generation 전달
- 같은 문서 연속 저장의 queue 순서
- enqueue 실패 뒤 로컬 TXT 성공 유지와 동일 batch 재시도
- store 재생성 뒤 marker의 동일 batch·operation ID 재생
- 실제 SQLite queue row와 document sequence
- IME 조합 중 enqueue 0건, 확정 뒤 1건
- 과거 generation의 최신 상태 위장 방지
- 고위험 실패 문구와 재시도 표시

## 10-4 연결

생성·이름 변경·이동·휴지통·복원·백업 복원·새 권 25화·Windows 가져오기
연결은 `LocalStructureSyncHandoff.md`에서 이어진다. operation claim,
네트워크 전송, retry backoff, commit, conflict, pull은 이후 단계 범위다.
