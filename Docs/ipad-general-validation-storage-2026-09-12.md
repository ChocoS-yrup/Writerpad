# iPad 실제 저장소 연결

공통 계획과 Windows 측 작업은 변경하지 않았다. 이번 결과는 로컬에만 보관한다. 설치·실기기 접근·실서버 요청은 모두 0회다.

## 연결한 제품 경로

`GeneralValidationProductAdapter`를 내부 단계 서비스 및 AppEnvironment의 생성 함수에 연결했다. 생성 함수 자체는 파일·큐·네트워크를 실행하지 않는다.

- 수신: 검증된 immutable snapshot → 기존 `SyncV2SnapshotPullService` → 실제 파일·SwiftData·동기화 SQLite 반영. 대상 revision/본문/메타데이터 해시, 대기열, 반영 보고서를 대조한 뒤 coordinator의 수신 예약을 종료한다.
- 저장·송신 준비: 기존 `LocalDocumentStore.saveCompared` → 실제 durable recorder → 일반 계약 큐 생성 → `claimNextGeneralContract`. 저장 영수증과 실제 생성된 operation/batch/device/build ID를 고정 본문 계약과 대조하여 요청을 반환한다.
- 성공 반영: 동일한 요청의 committed/revision 2 응답 → 기존 `completeContractStructure` → 실제 본문·메타데이터 해시·revision·큐 idle 확인. 실패 뒤 같은 adapter에서 완료나 저장을 다시 시도하지 않는다. coordinator 예약만 해제하고 영구 기록은 보존한다.

제품 경로는 파일 변경 전에 기존 송신 잠금과 계약 경로 준비를 검사한다. AppEnvironment에서는 기존 계정·binding·활성 작품·캐시된 ID_BASED/epoch 1 handshake·구조 기준을 읽기 전용으로 확인한다. 새로운 로그인·handshake 호출이나 권한 발급은 없다. 저장 단계에 사용한 계약 세대를 완료 단계에서 새로 발급받지 않는다.

`GeneralValidationMutation`으로 단계별 변경 권한을 제품 저장 작업에 전달했다. SQLite transaction 진입 및 COMMIT 직전, 메타데이터/파일 변경 경계에서 재검사한다. 변경 중 만들어진 보호 HTTP 세션은 이후 실행돼도 차단한다. 이 문맥은 추가 제한이며 기존 ReceiveValidation 잠금을 해제하지 않는다.

## 실행 전 체크포인트 계획

`GeneralValidationCheckpointPlan`은 호출자가 제공하는 전체 DB·메타데이터·파일 해시와 단계 표식을 값으로 보관하고 순서를 검사한다. 허용되는 순서는 `receiveWindows → sendUpdate`, `sendUpdate(저장 전) → sendUpdate(저장 후) → receiveFinal`, `receiveFinal → 완료`뿐이다. 인접 상태의 전체 해시가 모두 같은 경우 단계 표식만 바꿔도 거부한다. 잘못된 계획은 화면의 준비 상태를 해제하고 실행 기록을 예약하지 않는다.

이 자료형 자체는 예상 해시의 산출이나 출처를 검증하지 않는다. 단계 서비스는 받은 예상 해시와 실제 변경 결과를 비교하지만, 제품이 만드는 시간·식별자·수신 반영 행을 포함한 다음 전체 상태를 실행 전에 산출하는 제품용 구성은 아직 남아 있다. 이전 완료 보고에서 이 구성이 끝났다고 표현한 것은 과장이므로 정정한다.

## 검사 범위

신규 8개 검사는 실제 제품 파일 저장·SwiftData repository·SQLite enqueue/materialize/claim/complete·snapshot apply를 사용한다. 계정/기기/handshake와 recorder의 계약 전달 부분은 합성 fixture다. 실제 AppEnvironment의 계정·서버 handshake를 종단 간 실행했다는 뜻은 아니다.

수신 revision 1 → 실제 저장/큐 processing → 완료 revision 2/큐 completed → 최종 수신 revision 3을 확인했다. 다른 작품의 큐 행과 이벤트가 유지되며, 메타데이터 저장 실패와 대기 중 권한 해제는 복구 표식을 남기고 큐 선점 전에 중단한다. 준비 없는 계약, 잠긴 정책, 오래된 계약 세대, 변경 중 HTTP도 검사한다. 기존 본문 검증 회귀 14개를 함께 포함했다.

## 아직 실행하지 않는 부분

본문·revision·메타데이터 해시·큐 상태의 정상 전환 검사는 실제 저장소 경로에 연결됐다. 제품용 예상 상태 산출, 인증/handshake/조회 예산과 Windows 최종 대조를 확정한 뒤 실행 버튼에 연결한다. 현재 UI는 준비 검사까지만 제공한다. 실제 설치·송수신 승인을 요청할 단계는 아직 아니다.

기존 저장소 연결 검사 84개에 체크포인트 계획 및 준비 해제 검사를 더한 86개가 2026-09-12 저녁 재실행에서 모두 통과했다. 앞선 사용량 제한으로 인한 검사 보류 상태는 이번 결과로 대체한다. 최종 소스 234개는 작업 폴더와 고정본의 해시가 모두 일치한다. 새 검토 기록은 `build/ipad-general-validation-checkpoint-review-20260912/verification.json`에 있다.

기존 개발용 프로파일은 2026-09-12 18:19 KST에 만료됐고, 새 서명 빌드도 유효한 `com.chocos.writerpad.debug` 프로파일이 없어 실패했다. 프로파일 자동 갱신은 요청하지 않았다. 이전 서명 앱은 새 소스를 포함하지 않는다. Windows 전달 ZIP·실기기 설치·실서버 송수신은 실행하지 않았다.

서명 없는 실기기용 ARM64 빌드는 성공했다. 일반 검증·본문 검증·수신 보호 플래그와 새 코드의 바이너리 포함, 격리 테스트용 네트워크 코드의 바이너리 제외를 확인했다. 이 산출물은 설치 가능한 서명 후보가 아니다.
