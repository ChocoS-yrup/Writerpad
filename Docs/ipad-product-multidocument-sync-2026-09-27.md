# 실사용 다중 문서 저장·송수신 연결 — 2026-09-27

## 범위

`codex/ipad-product-sync-settings`에서 앞 단계의 작품별 활성화 UI와 함께 작업한다.
진단 앱의 추가 수동 확인을 요구하지 않는다. 기기 설치·실제 서버 쓰기·백업은 수행하지 않았다.
서버 API, 계약 0.2.0, Windows 구현, 교차 플랫폼 입력, 스키마와 RLS는 변경하지 않았다.
이 iPad 전용 변경 때문에 Windows 회신을 기다리지 않는다.

## 확인한 연결과 수정

기존 일반 앱 구성요소를 실제 TXT·SwiftData·SQLite에 연결하고 원격 transport만 합성 응답으로
대체했다. `AppEnvironment.live` 전체나 실서버 종단간 시험으로 집계하지 않는다.
계약 handshake와 구조 기준은 fixture가 승인한 상태에서 시작하며, 송신은 실제 dispatcher와
contract sender, 수신은 실제 snapshot puller와 local applier를 사용한다.

기존 보호 장치는 다음과 같이 유지된다.

- UUID 계약 작품의 관문을 닫아도 구형 큐로 후퇴하지 않는다. 하위 저장소가 이를 차단하고
  LocalDocumentStore가 문서별 인계 파일을 남긴다. 처음 의심했던 구형 큐 후퇴는 재현되지 않았다.
- 일반 계약 큐에 대기가 있으면 구조 의존성 때문에 같은 작품의 다른 문서 수신도 보류한다.
  문서 단위 동시 수신을 허용하도록 이 정책을 완화하지 않았다.
- 송신 완료 뒤 문서별 서버 revision이 독립적으로 전진하고, 수신은 새 송신을 만들지 않는다.

실제 빠진 연결은 설정의 재시도 버튼이었다. 기존 구현은 이미 SQLite 큐에 들어간 변경만
재시도하며, 각 문서의 미연결 인계 파일은 편집기에서 해당 문서를 다시 열어야 재생했다.

이를 `저장 기록 연결 및 재시도`로 보완했다.

- 활성화된 선택 작품의 활성 TXT 문서만 조회해 기존 `retryPendingSyncHandoff`를 호출한다.
  폴더·휴지통·다른 작품은 대상이 아니다. 본문 재저장이나 새로운 batch 생성은 하지 않는다.
- 큐가 비어 있어도 버튼을 표시한다. 전체 동기화가 꺼져 있거나 해결할 충돌이 있으면 비활성화한다.
- 현재 계정, 연결 소유자, 표시 중인 연결, 작품 활성 상태, ID_BASED handshake를 확인한다.
  계정·연결·작품 수명·관문·전역 설정·scene 변화와 화면 이탈/취소를 확인하며 재생한다.
- 저장 기록 일부를 연결하지 못하면 성공으로 표시하지 않는다. 연결된 기록의 큐 재시도는
  기존 송신기 검사를 거치고, 미연결 파일은 기존 방식대로 남는다.
- 여러 문서 전체를 하나의 원자적 트랜잭션으로 처리하지 않는다. 앞서 연결된 기록은 유지하고
  권한이 바뀌면 나머지 재생을 중단한다. 구조 기준이 없을 때 이를 우회하거나 임의로 승인하지 않는다.

Supabase 스킬에 따라 변경 목록과 [Swift user() 문서](https://supabase.com/docs/reference/swift/auth-getuser)를
확인했다. 클라이언트 표시 상태나 사용자 metadata를 새로운 권한 근거로 삼지 않고 기존 인증 서비스,
handshake와 송신기의 최종 권한 검사를 유지했다. SDK·키·서버 설정은 변경하지 않았다.

## 자동 검사

새 통합 검사는 다음을 포함한다.

1. 문서 A→B→A→C 저장 후 revision 1/7/3의 독립 전진, 한글·이모지·Unicode byte·빈 본문 보존,
   후속 서버 본문 수신과 구형 전송 미사용.
2. 관문 닫힘 중 문서 2개의 파일 인계 보존, LocalDocumentStore 재생성 뒤 정상 큐 연결.
   이는 프로세스 강제 종료나 SQLite 재시작 전체 시험은 아니다.
3. 계약 이력이 없는 LEGACY 작품의 기존 저장 경로 유지.
4. 실패 요청의 동일 ID·본문·해시 재전송과 그동안 저장한 다른 문서/같은 문서의 순서 유지.
5. 작품 단위 대기 중 수신 보류, 대기 해소 후 clean 문서 수신과 dirty 편집기 보호.
6. 설정에서 미개봉 문서 2개의 인계 연결, 본문 hash·메타데이터 불변, 실제 dispatcher 송신.
7. 재시도 handshake 중 계정·연결·작품 수명·화면 이탈·관문·전체 설정·비활성화·취소 8종 차단.
8. 구조 기준 부재 시 인계 파일 유지와 미완료 표시.
9. 다른 소유자, 오래된 화면 연결, 로그아웃 상태의 재시도는 네트워크 요청 전에 차단.

초기 5개 검사 중 2개는 fixture가 실제 앱 폴더 밖에 문서를 만들고 작품 단위 보호를
문서 단위로 기대해 실패했다. fixture를 `메인/원고`와 서버 부모 UUID에 맞추고 기대값을 수정했다.
이 과정에서 제품의 수신 보호를 완화하지 않았다. 수정 후 중간 선택 회귀는 **361개 통과**했다.

최종 선택 회귀 **499개 통과, 실패 0, 건너뜀 0**:

- AppEnvironment 116, LocalDocumentStore 17, LocalDocumentStoreRecovery 3,
  ReceiveValidationPolicy 18, SyncSettingsModel 6, GeneralSync 70, Handshake 130, SnapshotPull 139.
- Debug 격리 bundle, iPad Pro 11-inch (M5) / iOS 26.5 simulator,
  `WRITERPAD_ISOLATED_TESTS`, 빈 서버 URL/key, 고정 package 버전, 서명 비활성.
- 컴파일/실행 로그 `warning:`·`error:` 0건, xcresult `runtimeWarnings: []`.
- 로그: `/private/tmp/writerpad-product-multidoc-tests-v4.log`.
- 결과: `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.27_15-09-27-+0900.xcresult`.

일반 **Release 최적화 빌드 성공**, `arm64`·`x86_64` 산출물 확인.
DEBUG·복구 진단·격리 테스트 플래그를 추가하지 않았다. 빈 서버 URL/key,
별도 `.productreleasecheck` bundle suffix, 서명 비활성으로 빌드만 수행했으며 설치하지 않았다.
로그 `warning:`·`error:` 0건: `/private/tmp/writerpad-product-multidoc-release-v1.log`.

## 다음 범위

작품 전환·재로그인·재실행으로 handshake/구조 기준이 없는 실제 일반 앱의 재개 UX를 확인한다.
현재 재시도는 구조 기준을 임의로 만들지 않으므로 수신 경로가 기준을 마련해야 한다.
관련 iPad 변경을 한 PR로 모아 최종 head에서 한 번 검토한다.

후속 구현은 `ipad-product-sync-resume-2026-09-27.md`에 기록했다.
본문 수신 대신 기존 서버 기준의 읽기 전용 비교로 파일 인계의 재개 준비를 보완했다.
