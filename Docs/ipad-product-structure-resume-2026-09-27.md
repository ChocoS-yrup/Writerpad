# 로컬 완료 구조 기록의 제품 재개 — 2026-09-27

## 범위와 재현

- 기준: PR #45 병합 `f97995845b28a0d0888e0400eb671ee6c8f1ba8d`.
- 브랜치: `codex/ipad-product-structure-resume`.
- 일반 앱의 열린 작품 자동 재개와 설정 재시도를 보완한다.
- 실제 TXT·SwiftData·SQLite·binder journal·계약 recorder를 사용하고 원격 transport만 합성 응답이다.

관문이 닫힌 상태에서 화 이름을 변경하면 로컬 파일·metadata는 반영되고 고정 batch를 가진
binder journal이 남는다. 기존 `SyncV2ProjectHandoffResumer`는 본문 인계만 조회해,
구조 기록만 남았을 때 미처리 수 0을 반환하고 큐 등록·송신을 하지 않았다.
수정 전 통합 시험에서 journal 잔존, 큐 0건, 송신 0건을 재현했다.

첫 fixture는 화를 권 폴더 없이 만들어 제품 규칙에 거절됐다. `메인/원고/1권`으로 바로잡은
재현 결과가 `/private/tmp/writerpad-structure-resume-red-v2.log`다. 제품 원고 규칙은 바꾸지 않았다.

## 구현

1. binder protocol에 구조 기록 존재 조회와 **송신 인계 전용** 재시도를 추가했다.
2. 새 로컬 구조 거래는 파일 변경 전에 기존 recorder에서 서버·계정 출처를 읽어 journal에 남긴다.
   최초 durable batch에도 같은 출처를 복사한다. 이전 기록에 현재 연결 정보를 소급해서 붙이지 않는다.
3. 자동/설정 재시도는 동일 작품의 journal 한 개가 `metadataSaved`이고, 고정 batch·거래 ID·출처가
   모두 맞을 때만 기존 승인 포함 recorder를 호출한다. 이름 변경/이동, 생성, 새 권, 순서 변경이 대상이다.
4. 작품 구조 mutation gate 안에서 재생하며, 일반 journal 복구도 같은 gate로 직렬화했다.
   기존 alias 이관은 gate 밖의 기존 경로에 남겨 중첩 gate 획득을 피한다.
5. recorder의 최종 SQLite 승인 검사까지 호출자 수명 검증을 전달한다. enqueue 뒤에도 승인을
   재확인하고 원래 journal bytes가 그대로일 때만 성공한 인계 표식을 제거한다.
6. 공통 resumer가 구조 기록을 먼저 확인하고, 같은 인증·연결·작품·설정·전경·서버 기준 검사를 거친다.
   구조 기록이 보류되면 뒤의 본문 인계를 재생하지 않는다. 기존 불확실 큐의 receipt 재시도는 유지한다.
7. 작업 화면과 설정의 제품 조립에 binder를 전달했다. 보류는 기존 `저장 기록 확인 필요` 안내를 이용한다.

본문을 다시 쓰거나 새 요청 UUID를 생성하지 않는다. 서버 API·계약·SQL·RLS·Windows·교차 플랫폼 입력·
패키지·서명 구성은 바꾸지 않았다. Supabase 스킬의 변경 목록·인증 문서 확인을 거쳐 기존 인증 경계를
유지했으며, 사용자 metadata·새 관리자 권한·서버 모드 전환은 추가하지 않았다.

## 의도적으로 자동 처리하지 않는 기록

- 파일 작업 미완료(`prepared`, `filesApplied`), batch 없음, 손상 journal.
- 작성 당시 서버·계정 출처가 없거나 현재 연결과 다른 기록.
- 휴지통 이동/복원/영구 삭제/전체 비우기. 후속 파일 정리가 포함될 수 있어 이번 전송 전용 경로에서 제외한다.
- 여러 journal이 동시에 남은 경우. UUID 파일명으로 인과 순서를 추정하지 않는다.
- recorder 실패·서버 크기 제한. 표식을 지우거나 완료로 표시하지 않는다.

위 기록은 기존 거래 복구와 별도 후속 검토 대상으로 남긴다. 이 단계로 구조 변경의 모든 복구,
미개봉 작품 전체 재개, OS background 전송이나 실기기 송수신이 끝났다고 선언하지 않는다.

## 검증

새 검사 4개:

- 본문 인계 없이 이름 변경 journal만 남아도 읽기 전용 서버 기준 준비 후 같은 batch/source로 큐 등록·송신.
  반복 재개의 중복 없음, 일반 계약 큐 완료와 구형 송신 0건 확인.
- 파일 단계 2종, 출처 없음/다름, batch 없음, 손상, 여러 기록, 닫힌 관문에서 journal bytes·본문 유지.
- recorder 내부 비동기 경계에서 호출자 권한이 바뀌면 SQLite 미등록과 journal 보존.
- 설정 재시도에서 폴더 생성·새 권 생성 기록을 연결하고 합성 송신 완료.

중간 바인더 기존 검사 44개는 통과했다. 새 송신 fixture에는 기존 서버 tree-order 기준도 추가했다.
해당 기준이 없으면 송신기가 거부하는 것이 정상이며, 제품의 기준 검사를 완화하지 않았다.
완료된 큐 source는 복구 상세 API에서 제외되므로 원본 비교는 완료 전 수행한다.

최종 확장 회귀 **556개 통과, 실패/건너뜀 0**, 컴파일 경고·오류 0건,
xcresult 요약의 `runtimeWarnings: []`.
AppEnvironment 116, LocalBinderCommandService 44, LocalBinderFolderSync 6,
LocalBinderRepository 16, SyncSettingsModel 6, GeneralSync 73, Handshake 148, SnapshotPull 147.
전체 suite나 실제 서버 시험의 결과가 아니라 위 8개 class의 선택 회귀다.

- xcresult: `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.27_23-12-28-+0900.xcresult`.
- 일반 Release 빌드 성공(exit 0), `arm64`·`x86_64` 확인, 컴파일 경고·오류 0건.
  DEBUG·진단·격리 테스트 컴파일 플래그를 추가하지 않은 Release 구성이다. 설치·실행 증거는 아니다.

- 확장 회귀 로그: `/private/tmp/writerpad-structure-resume-regression-v1.log`.
- Release 로그: `/private/tmp/writerpad-structure-resume-release-v1.log`.
- 계약 검증 통과: 0.2.0, 7 schemas / 12 transitions / 15 storage-name / 4 atomic-wire / 7 document-wire.
- canonical SHA-256: `416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670`.
- 격리 simulator bundle, 빈 서버 URL/key, package lock 고정, 서명 비활성. 실제 기기·서버 조작 없음.
- 관련 변경은 이 브랜치의 로컬 체크포인트로 정리한다. push/PR/원격 검토/병합은 수행하지 않았다.

## 후속 마무리

같은 브랜치에서 이동·순서 변경, 재개와 명시적 복구의 동시 실행, 작품·계정·전경 변경 경계를
추가 점검한다. 현재 4개 신규 테스트가 모든 구조 명령이나 실제 OS 수명을 검증한 것은 아니다.
관련 보완을 마친 최종 head만 한 PR로 검토 요청하며, iPad 전용 범위에는 Windows 회신을 요구하지 않는다.
