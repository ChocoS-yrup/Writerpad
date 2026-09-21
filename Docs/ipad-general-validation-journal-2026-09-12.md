# iPad 일반 검증: 영구 시도 기록 연결

사용자의 “아이패드 측 기록 연결 진행”에 따라 로컬 구현·격리 검사·보호된 검토 후보를 준비했다. 실제 설치와 서버 송수신은 이번 작업에 포함하지 않았다.

## 이번에 연결한 동작

`GeneralValidationExecution.swift`에 Windows와 대조한 `general-body-20260912-v1`과 다음 세 단계를 고정했다.

| iPad 단계 | 기록과 예산 |
| --- | --- |
| receiveWindows | 고정한 documents / folders / tree_orders GET 각 1회. 본문 revision 1·정렬 revision 2의 완전성 및 로컬 적용 검증은 단계 완료 호출 전 필요하다. |
| sendUpdate | 실제 큐의 operation/batch/build/device ID를 보존한 document_commit(update) 1회. 문서·부모·이름·ID_BASED/epoch 1·base revision 1·128바이트 본문·structure revision 1을 실제 제품 builder와 비교한다. 성공 응답은 committed / revision 2를 요구한다. |
| receiveFinal | 위 세 테이블 GET 각 1회. Windows 본문 revision 3 및 로컬 반영 검증 후에만 완료할 수 있다. |

본문은 100 → 128 → 159바이트이며, iPad 송신 본문 SHA-256은 `e2e2247ad6b98784bd4fdeaf45401b5a7805f58659f98abcd508f489f252eb15`다. 서버 작품과 iPad local 작품의 서로 다른 UUID를 유지한다. lease·정렬 쓰기·자동 재시도·복구 조회는 이 실행 기록 구성에 포함하지 않는다.

이 GET 구성은 새 기록 모듈의 제한이다. 실제 인증·handshake와 최종 snapshot 조회 열/순서/완전성 판정까지 승인된 실서버 요청 목록으로 완성한 상태는 아니다.

## 영구 기록과 중단

고정 계획 ID와 단계 이름으로 `.jsonl` 파일을 단독 생성한다. 이미 존재하는 파일은 성공·실패·빈 파일·부분 기록 모두 재사용하거나 지우지 않는다. 파일은 0600 권한으로 생성하며, 디렉터리를 먼저 열고 openat / O_EXCL / O_NOFOLLOW를 사용한다. 심볼릭 링크인 기록 폴더와 이전 단계 파일을 거부한다.

예약 행과 디렉터리를 fsync한 뒤 요청 시도 행을 쓰고, 매 행을 fsync한다. 쓰기·flush 실패 시 전송 전에 중단한다. 이미 만들어진 기록은 실패해도 보존한다. 저장되는 값은 계획·단계·사건 종류·순번·요청 SHA-256뿐이다. 계정·bearer·본문·임의 오류 문자열을 기록하지 않는다.

`reserved → attempt → responseAccepted`를 요청마다 기록한다. HTTP 응답만으로 `completed`를 쓰지 않는다. 소유 서비스가 완전한 원격 기준과 로컬 파일/큐 결과를 검사한 후 `completeAfterLocalValidation`을 호출해야 완료된다. 이 callback이 실패하면 stopped로 남는다.

다음 단계는 직전 단계의 예약·정확한 개수의 시도/응답 쌍·일치하는 해시/순번·완료 행을 모두 확인해야 예약할 수 있다. 잘린 기록·잘못된 JSON·64KiB 초과 기록은 거부한다. 응답 유실, 권한 해제, 만료, 중복 요청, 순서 변경 또는 기록 실패 이후에는 새 실행 객체를 만들더라도 같은 단계의 기존 파일 때문에 재송신할 수 없다.

## 실제 HTTP 경계 연결

ReceiveValidationURLProtocol의 session 등록 시 실행 문맥을 고정한다. 전송 직전에 요청 method/URL/body 바이트·bearer·전경/계정/binding/local 상태 검사 callback·만료를 검사하고, 시도 행을 영구 기록한 뒤 다시 권한/로컬 상태를 검사한다. 그 후에만 network closure를 호출한다. 응답에서도 기존 인증 권한 검사와 실행 문맥 검사를 통과해야 responseAccepted를 기록한다. 206을 포함한 200 이외 응답은 중단한다.

Range, Range-Unit, public 이외 schema, 검토하지 않은 Prefer 값과 바뀐 bearer를 거부한다. 직접 contract HTTP도 실행 문맥이 있으면 이 session을 사용한다. 로그인 과정에서 만들어진 캐시 SDK client를 새 실행 단계에 재사용하지 않아 문맥이 누락되지 않게 했다.

검토 빌드의 `GeneralSyncValidationScope`는 데이터 요청에 기록 문맥을 필수로 요구한다. 기존 ReceiveValidation/BodyValidation 송신 잠금은 계속 독립적으로 적용된다. 기록 객체를 만드는 것으로 인증·송신 권한이 생기지 않는다. compiled scope의 RPC 허용 목록과 lease 문서 목록도 비어 있다.

## 구현 범위와 남은 실행 구성

기록과 HTTP 경계의 연결은 완료했다. 실제 일반 검증 UI가 아직 이 객체를 생성하거나 권한을 발급하지는 않는다. `checkCurrent`, `checkLocal`, 완료 callback의 실기기 상태 연결도 이번 결과로 완료됐다고 주장하지 않는다.

다음 단계에서 명시적인 전경 일반 검증 UI/서비스에 실제 계정·binding·화면/앱 수명·로컬 파일과 큐 상태 검사를 연결해야 한다. 기록 루트는 하나의 고정된 앱 전용 위치여야 하며 재시도 때 새 디렉터리를 만들어 제한을 우회해서는 안 된다. 현재 모듈은 호출자가 그 루트를 전달하게 되어 있고 앱 실행 시 자동 생성하거나 재시작하지 않는다.

완전한 snapshot 판정과 로컬 반영 이후의 완료 호출, 인증/handshake 요청 목록·예산, 실제 큐의 최종 요청 바이트까지 연결하고 양쪽 후보를 대조한 뒤 설치·서버 요청 범위를 승인받는다. 현재 사용자가 앱에서 누를 추가 버튼은 없다.

## 검증 및 산출물

실제 계정·원고·DB 대신 전용 Simulator, 합성 파일/요청, 모의 HTTP와 `WRITERPAD_ISOLATED_TESTS` 차단을 사용했다. 신규 기록 검사에는 단계 순서·재시작 중복 차단·기록 내용 최소화·저장 실패·기록 중 권한 해제·응답 유실·늦은 응답·잘못된 revision·부분 HTTP·헤더/본문 변경·심볼릭 링크·SDK 캐시·실제 contract HTTP 연결을 포함했다.

상세 검사 수·이름·로그 해시는 test-summary.json에, 고정 소스/앱 해시·서명은 candidate-verification.json에 기록한다. 실제 기기 재시작이나 전원 차단 시험을 수행했다는 의미는 아니다.

Supabase SDK와 서버 계약은 변경하지 않았다. 기존 호출 경로는 [공식 Swift RPC 문서](https://supabase.com/docs/reference/swift/rpc)와 대조했다. changelog markdown은 도구의 content-type 제한으로 읽히지 않았으며 SDK 업그레이드나 신규 서버 기능은 도입하지 않았다.

## 확정 결과

최종 검사 40개가 통과했다(신규 기록 15개, 관련 기존 보호 25개). 앞선 개발 검사 37개·39개를 추가 실적처럼 합산하지 않았다. 전용 합성 Simulator를 종료했다.

후보: `ipad-general-journal-review-20260912`. iPad 빌드와 strict/deep 서명, 기존 Staging 설정·entitlement·프로파일 일치, 보호 플래그 3개와 새 기록 심볼, 앱 ZIP CRC·파일 해시를 검증했다. 인증서 체인의 온라인 폐기 조회를 수행했다는 의미는 아니다.

- source digest: `8cc794fb7ed9602173049f4d4ed2a37de964f7f94dda02b4af1846475a361049`
- app ZIP SHA-256: `a6b22fae611a75bebd14aaf1a0729b945eb0a5bb7d3b307aa541a750c20a4f2d`
- app tree digest: `fd4fc1ff43cbe0172fd4b4f92e3e9ac44712e569088cf47264087448b5061cc0`
- 기존 프로파일 만료: `2026-09-12T18:19:25+09:00`

소스 231개를 고정했고 이전 검토 후보 대비 7개 파일을 변경했다. 앱·프로파일·원시 로그·xcresult는 private에 보존한다. 설치된 앱과 실제 데이터에는 접근하지 않았다.
