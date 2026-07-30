# 10-5 서버 크기 preflight와 no-op 저장

## 완료 범위

서버 `commit_document`의 본문 제한과 동일한 UTF-8 10,485,760 bytes를
`SyncV2Store`의 영구 queue 등록 경계에서 검사한다.

- 정확히 10MiB인 본문은 `pending` operation으로 기록한다.
- 10MiB를 1 byte라도 넘으면 operation payload와 ID를 그대로 저장하되
  `blocked`와 `CONTENT_TOO_LARGE`를 기록한다.
- 대응하는 `sync_documents`도 `blocked` 상태와 같은 오류 코드를 보존한다.
- 차단은 로컬 TXT 저장이나 자동·수동 백업 실패로 변환하지 않는다.
- 편집기에는 `로컬 저장됨 · 서버 크기 제한 초과`를 표시한다.
- 앱을 종료한 뒤 문서를 다시 열어도 SQLite의 차단 상태를 복원한다.
- 같은 batch를 재생해도 같은 차단 operation을 다시 만들지 않는다.

현재 단계에는 서버 요청 실행기가 없지만, 후속 실행기는 `blocked` operation을
claim하거나 `commit_document`로 보내면 안 된다.

## no-op 저장 조건

일반 `document_save`만 다음 조건을 모두 만족할 때 새 operation을 만들지 않는다.

1. 기존 서버 revision이 1 이상이다.
2. 문서와 새 snapshot이 모두 live 상태다.
3. 저장할 상대 경로가 `server_path`와 같다.
4. 저장할 본문이 `base_content`와 같다.
5. 해당 문서에 `completed`·`cancelled` 이외의 활성 operation이 없다.

최초 업로드, rename·move·delete·restore, 백업 복원, 트리 순서와 휴지통 purge는
이 최적화로 생략하지 않는다. no-op batch 자체는 `completed`로 남겨 동일 batch
ID의 payload 일치 여부와 멱등 재생을 계속 검증한다. 문서 sequence와 revision은
증가하지 않는다.

## 서버 제한 초과 원고의 로컬 성능 경계

10MiB를 넘는 원고도 로컬 편집·저장·백업·복원은 계속 지원하므로 다음과 같이
대용량 전용 비용 상한을 둔다.

- 백업 화면은 목록을 먼저 표시하고 사용자가 스냅샷을 선택하기 전에는 본문을
  읽거나 diff를 계산하지 않는다.
- 미리보기는 최대 12,000 UTF-16 code unit만 SwiftUI에 전달한다.
- 현재본이나 백업이 262,144 UTF-16 code unit을 넘으면 줄 diff를 생략한다.
- 1MiB 이상 원고의 자동 저장 백업은 5분 안에 다시 전체 TXT를 쓰지 않는다.
  문서 전환·닫기·복원 전 등 중요한 사건 백업은 이 제한의 영향을 받지 않는다.
- 복원 전 강제 백업은 직전 로컬 저장 결과의 UTF-8 bytes와 SHA-256을 재사용한다.
- 500,000 UTF-16 code unit을 넘는 원고에서는 매 입력마다 수행하던 동기 타자기
  레이아웃을 생략하고 UIKit의 기본 커서 가시성에 맡긴다.

자동 회귀 테스트는 대용량 미리보기 상한, 자동백업 시간 제한, 복원 전 현재본
보존, 동기 타자기 레이아웃 생략을 검증한다.

## 11단계 정지 경계

operation claim, Supabase RPC 호출, retry/backoff, lease, 성공 응답에 따른
server revision·base 갱신은 구현하지 않는다.
