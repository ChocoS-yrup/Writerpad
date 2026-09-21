# iOS 전용 컨테이너·파일 보호/생명주기·앱 target 결합 결과

2026-09-14. 사용자 요청의 구현·오프라인 검사·서명 없는 iOS 빌드를 완료했다. 기존 WriterPad 앱과 원본을 보존하면서 **별도 격리 iOS target**에 앞선 물리 adapter를 연결했다. 기기/시뮬레이터를 실행하거나 설치하지 않았다.

## 결과

- `OfflineAdapters/IOSBoundaryApp/IOSBoundaryApp.xcodeproj`의 `ReceiveBoundary` target을 추가했다. 검토된 로컬 Swift adapter 소스 7개를 직접 컴파일하며 외부 패키지·기존 AppEnvironment/로그인/Keychain/동기화 코드를 연결하지 않는다. 기존 `WriterPad.xcodeproj`와 제품 앱 소스는 변경하지 않았다.
- 후보 bundle 문자열은 `com.chocos.writerpad.receiveboundary`다. 실제 App ID 등록·서명 profile 발급·설치 완료를 뜻하지 않는다. iOS 17+ iPad용 Debug generic iOS 빌드를 통과했다. Release 빌드나 실행 검사를 했다고 표시하지 않는다.
- **신규 호스트 Swift 19개 + 기존 Swift 영향 74개 + 기존 Python 영향 110개 = 최종 고유 203개 통과, 실패 0.** 기존 영향 합계는 184개다. 중간 실행 74/92개, 과거 184개 보고, 개별 실패 주입 반복을 다시 더하지 않는다.
- 생성된 앱의 Info.plist와 Mach-O를 읽어 후보 bundle ID·iPad family·네 방향·단일 scene·파일 공유/문서 제자리 열기 금지·background mode 없음 및 unsigned 상태를 확인했다. 세 Mach-O에 LC_CODE_SIGNATURE가 없고 `_CodeSignature`/embedded.mobileprovision도 없다. 앱을 서명하거나 실행해 확인한 결과가 아니다.
- baseline_applied/execution_allowed 및 기존 경계의 baseline_ready·app_binding_created·편집/송신/자동 수신은 계속 false다. 합성 성공만 syntheticReady로 표시한다. 실제 local project UUID는 발급하지 않았다.

## 연결한 경계

| 대상 | 구현 |
| --- | --- |
| 시작 | UIKit 보호 데이터 상태·앱 notification·SwiftUI scenePhase만 관측. startup에서 container/store/identity를 만들거나 자동 합성 적용하지 않음 |
| 명시적 합성 확인 | 버튼에서 OS가 제공한 NSHomeDirectory와 후보 bundle을 확인하고, 별도 worker에서 고정 합성 fixture만 처리. 기존 원고 선택/import·실제 Windows 자료 입력 경로 없음 |
| 컨테이너 | 전용 앱 home 아래 `Library/Application Support/WriterPadReceiveBoundary-v1`. `container.json`은 종류/bundle/절대 경로/version을 결합. 다른 path·누락/변조 seal·외부 파일·기존 store·심볼릭 링크를 차단 |
| 파일 보호 | 새 전용 directory·seal·lock·pending에 complete를 설정하고 확인. pending은 본문 bytes 쓰기 전에 보호 등급 확인. 기존 파일/디렉터리의 보호 등급이 약하거나 없으면 자동 수정 없이 차단 |
| 보호 속성 표현 | Foundation의 FileProtectionType.complete 또는 같은 raw 문자열만 허용. none/UnlessOpen/UntilFirstUserAuthentication·누락/잘못된 타입은 거부 |
| 생명주기 | 비활성/백그라운드/종료 notification·protected-data 비가용 상태에서 thread-safe generation 변경. 기존 lease와 표시 readiness 취소. 재활성/잠금 해제 후에도 이전 lease 재사용/자동 재개 금지 |
| worker/완료 | 파일 작업은 main actor 밖에서 수행해 UI notification 처리를 막지 않음. 파일 생성·검증·쓰기·완료/반환 중 lease 확인. 완료를 UI에 게시하기 직전 main actor에서도 같은 lease 확인 |
| 부분 기록 | 이전 물리 저장소의 다섯 영역/9개 record/head 검증을 유지. 취소가 pending을 남겼으면 보존·차단. 새 명시적 작업이어도 불명확한 기록을 추정 복구하지 않음 |
| 재개 | 완결된 공개 head는 새 명시적 합성 작업과 유효한 새 lease로 재읽을 수 있음. 실제 A/B run이나 오래된 서버 결과를 재개하는 권한이 아님 |

UIKit/NSFileManager의 notification·보호 속성 선언은 설치된 iPhoneOS26.5 SDK 헤더와 컴파일로 확인했다. 실제 기기의 암호화/잠금 효과를 관찰한 것은 아니다. 이번 호스트 보호 검사에서는 inode별 보호 대역과 새 임시 fake home을 사용했다.

## 수정한 차이·빌드 기록

1. `ios-build-01.log`: 최초 로컬 SwiftPM package 결합에서 사용자 cache/module cache 쓰기가 sandbox에 막혀 dependency 평가 단계에서 종료했다. 전역 cache 권한을 확대하거나 package를 다운로드하지 않고, 새 앱 target이 같은 로컬 adapter 소스를 직접 컴파일하도록 변경했다. 당시 project 원문을 `project-before-local-source-link.pbxproj`로 보존했다.
2. `ios-build-02.log`: 서명 없는 iOS 빌드 성공. iPad 방향 설정 경고를 네 방향 명시로 수정했고 `ios-build-03.log`도 성공했다.
3. 생성 산출물의 첫 확인에서 **UIFileSharingEnabled가 생략되고, 단일 scene 의도와 달리 UIApplicationSupportsMultipleScenes가 true**인 차이를 발견했다. `product-check-01.json`과 당시 Info.plist를 보존했다. 판정 기준을 완화하지 않고 명시적 source Info.plist로 수정했다.
4. `ios-build-04.log`: 최종 빌드 성공. `ios-product-verification.json`에서 단일 scene·공유/문서 제자리 열기 false·unsigned 조건을 다시 확인했다. 사용자 수준 AppIntents 의존성이 없어 metadata extraction을 건너뛴 경고는 남아 있으나 빌드 실패가 아니다.
5. xcodebuild가 일반 초기화 중 CoreSimulator 서비스/런타임 observer에 접근하려다 제한 환경에서 경고를 냈다. 기기/시뮬레이터 설치·부팅·앱 실행 명령은 하지 않았으며 해당 경고를 없애기 위해 서비스를 조작하지 않았다.

`swift-tests-01.log`는 변경된 공통 코드의 기존 74개 통과다. `swift-tests-02.log`는 신규 18개 포함 92개 통과, 속성 표현 회귀 검사 1개를 더한 `swift-tests-03.log`는 최종 93개 통과다. `python-impact-01.log`의 기존 110개도 통과했다. 이번 Swift/Python 테스트 실패는 없으며 최초 빌드·산출물 확인 실패와 모든 중간 로그를 보존했다.

신규 검사에는 활성/보호 상태 미확정, 오래된 lease 재사용, 쓰기 중 비활성화, 보호 설정 실패 시 빈 pending 유지, 완료 후 보호 약화, 준비/적용 반복 무변경, seal·root·bundle 불일치, 실제 후보 거부와 외부 합성 원본 보존이 포함된다. 실제 iOS controller/notification을 호스트 대역으로 실행했다고 부르지 않는다.

## 보존

작업 전 manifest 5,375개 중 승인된 공통 패키지 수정 4개를 제외한 **5,371개 파일의 SHA 대조 차이 0**이다. 기존 변경 파일은 Package.swift, LocalBoundary.swift, PhysicalBoundaryStorage.swift, SafeFiles.swift이며 이전 원문/변경 전후 SHA를 보존했다. 기존 host 경로는 기본 no-op 보호 hook과 종전 임시 namespace를 유지하며 영향 검사를 통과했다.

이전 단계 5,354개 manifest는 그 단계의 승인된 변경 후 SHA를 반영한 상태로 이번 시작 전에 차이 0이었다. 서로 다른 대조 집합을 합산하지 않는다. 기존 WriterPad project가 보존 manifest에 포함돼 있으며 앱/기존 설정·Python 코드/검사·이전 Swift 검사·설치물/이전 unsigned 산출물은 변경하지 않았다.

기존 충돌·미송신 18/19바이트 원본 2개·종료 HTTP 323/Auth 12/writes 17·만료 2026-09-13 15:00 KST·원본 증거와 J02/J04/J05/J07 및 기존 자동 주기 의미를 유지한다. 새 unsigned 앱 산출물은 이번 build 하위에만 보관했다.

서버 요청·credential/로그인 갱신·실제 Windows 관찰/생성 자료 재검토·실제 local UUID 발급·서명/profile·설치·기기/시뮬레이터 실행·실제 baseline 적용·관문/hold/prod 변경은 수행하지 않았다. 이번에 한 것은 **새 격리 앱의 unsigned 컴파일과 산출물 읽기**이며 기존 설치물 실행은 아니다.

## 남은 조건

1. **iOS 실기기 실행 검증:** 잠금/해제 notification 순서, complete 보호의 실제 읽기 차단, 백그라운드/강제 종료·전원 손실·디스크 오류에 대한 실기기 검증은 미완료다. host 대역/프로세스 검사와 iOS 컴파일로 이를 대체하지 않는다. 향후 별도 서명/설치/기기 실행 범위가 필요하다.
2. **실제 수신 연결:** 새 앱은 고정 합성 fixture만 처리한다. Windows draft→실제 수신 Expected/생성 의미 mapper, 실제 A/B transport·시간/예산/run·원문 완전성 및 baseline 채택은 미완료다. Python 계약 검증기를 iOS 코드로 연결했다고 표시하지 않는다.
3. **제품 앱 기능 연결:** 기존 WriterPad 편집·DB·프로젝트 목록에 새 저장소를 결합하지 않았다. 새 앱은 합성 확인 화면이 있는 독립 target이다. 앱 서명 App ID 등록, 실제 local identity, 원고 편집/송신 경로의 연결도 별도다.
4. 불명확한 pending의 자동 복구, 외부 writer의 동시 경로 교체 및 일관된 전체 과거 데이터로의 rollback 방어 한계는 이전 단계와 같다. 실제 홈 경로가 이동한 자료도 현재 seal/binding과 맞지 않으면 보정 없이 차단한다.

## 전달물과 사용자가 할 일

`build/ipad-ios-boundary-offline-20260914/ipad-ios-boundary-offline-result-20260914.zip`은 소스·새 Xcode project/명세·재현 검사·최초/최종 로그·산출물 검증/보존 hash를 포함한다. 기존 원고/credential/설치물을 넣지 않는다. 새 unsigned 앱 자체는 로컬 `ios-build/Build/Products/Debug-iphoneos/ReceiveBoundary.app`에 보관하며 전달 ZIP은 설치 패키지가 아니다.

**지금은 결과 ZIP을 보관하면 된다. Windows 기록을 맞출 때만 “iPad 격리 iOS target 결합·unsigned 빌드 완료, 신규 19개/기존 184개 총 203개 통과, 실제 입력·실기기 검증은 미완료”로 결과 접수용 전달하면 된다. 추가 계약 문서 왕복이나 앱 설치/버튼 조작은 필요 없다.**

다음 연결 작업은 실제 Windows 인계 출력과 수신 입력의 매핑이다. 실제 기기 보호/생명주기 검증은 필요한 서명·설치 조건을 갖춘 별도 실행 단계로 남긴다. 이번 결과만으로 어느 단계도 자동 실행하지 않는다.
