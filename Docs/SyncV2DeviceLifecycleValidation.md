# SYNC-004 실기기 로컬 수명주기 검증

## 공개 검토본의 출처

게시용 브랜치는 `codex/ipad-lifecycle-review`다. 아래 `72ee8b8` 등은 검증 당시의
로컬 원본 브랜치 커밋이며 공개 원격 커밋으로 간주하지 않는다. 원본 브랜치와 로컬
증거는 보존하고, 게시용 이력은 `d791b27` 기준선 위에 검토본을 별도로 커밋한다.
제품 코드·테스트·빌드 설정은 검증한 원본과 동일하며 문서에서 실제 기기 UDID와
설치 컨테이너 식별자만 제외했다. 실제 원고·화면·xcresult·DB는 저장소에 포함하지 않는다.
아래 로컬 증거 경로는 검증 담당자의 보관 위치이며 다른 환경에서 접근 가능하다는 뜻은 아니다.

## 격리 조건

일반 제품의 `AppEnvironment.live()`와 실제 분할 workspace를 사용하되,
앱과 테스트 러너의 식별자를 모두 분리한다. 기존 앱을 삭제하거나 그 컨테이너를
복사·변경하지 않는다. 검증용 앱도 자동 삭제하지 않고 생성 원고를 보존한다.

- 앱: `com.chocos.writerpad.lifecyclevalidation`
- 테스트 번들: `com.chocos.writerpad.uitests.lifecyclevalidation`
- 표시명: `ChocoS 수명주기 검증`
- 서버 설정: URL과 publishable key를 빈 값으로 덮어쓴다. 로그인하지 않는다.
- `WRITERPAD_ISOLATED_TESTS`나 `WRITERPAD_AUTOSAVE_ISOLATED`는 사용하지 않는다.
  재실행마다 초기화되는 메모리 저장소로 영구 저장 검증을 대신하지 않는다.
- 테스트는 전용 테스트 번들이 아니면 앱 실행 전에 건너뛴다.

## 자동 검증

`WriterPadShellUITests.testIsolatedLifecyclePreservesBothPanesAfterHomeAndRelaunch`는
실행마다 `Lifecycle Synthetic <run>` 작품을 만들고 001화/002화를 좌우 편집기에
연다. 서로 다른 합성 표식을 입력한 뒤 홈 화면 전환·복귀와 XCTest 종료·재실행에서
두 본문의 정확한 일치를 검사한다. 홈 전환 전에 두 본문을 먼저 확인해 분할
생성 실패와 scene 복귀 실패를 구분한다. 각 검사 직전 화면을 첨부하며, 모든
검사를 통과하면 생성 작품과 기대 본문도 xcresult 첨부로 남긴다.

이 테스트는 자동저장/비활성 저장 중 어느 것이 먼저 완료됐는지, OS가 실제로
suspend했는지, 저장 직전 강제 종료된 입력을 복구했는지를 증명하지 않는다.
XCTest `terminate()`는 사용자의 앱 전환기 강제 종료와 구분한다.

실행 예시에서 `DEVICE_UDID`, `DERIVED_DATA`, `PACKAGES`는 실행 환경에 맞게 지정한다.
DerivedData는 소스 worktree와 **대소문자만 다른 경로를 사용하지 않는다**.
실기기에서는 앱과 XCTest 러너용 설치 슬롯이 모두 필요하다. 설치 한도나
UI 자동화 초기화 오류가 있으면 기존 앱을 임의로 삭제하지 말고, 수동 실기기
검사와 별도 시뮬레이터 자동 검증으로 나누어 기록한다.

```sh
xcodebuild test -project WriterPad.xcodeproj -scheme WriterPad \
  -configuration Debug -destination "platform=iOS,id=$DEVICE_UDID" \
  -derivedDataPath "$DERIVED_DATA" -clonedSourcePackagesDirPath "$PACKAGES" \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -onlyUsePackageVersionsFromResolvedFile -allowProvisioningUpdates \
  -parallel-testing-enabled NO \
  -collect-test-diagnostics never \
  -only-testing:WriterPadUITests/WriterPadShellUITests/testIsolatedLifecyclePreservesBothPanesAfterHomeAndRelaunch \
  WRITERPAD_BUNDLE_SUFFIX=.lifecyclevalidation \
  WRITERPAD_TEST_BUNDLE_SUFFIX=.lifecyclevalidation \
  'WRITERPAD_DISPLAY_NAME=ChocoS 수명주기 검증' \
  WRITERPAD_SUPABASE_URL= WRITERPAD_SUPABASE_PUBLISHABLE_KEY=
```

`-collect-test-diagnostics never`는 실패 시 전체 시스템 진단 수집만 생략한다.
테스트 assertion/로그/화면 첨부를 제거하거나 실패를 통과로 바꾸지 않는다.

## 수동 잠금·강제 종료

1. 자동 테스트 또는 사용자 합성 원고 입력 후 전용 앱의 `Documents`를 새 로컬 증거 폴더에 복사한다.
   생성 원고의 본문 바이트 수와 SHA-256을 기록한다.
2. debugger/테스트 러너 없이 전용 앱을 실행한다. 실제 기기에서 가로 분할의
   좌우 원고가 맞는지 확인한다.
3. 사용자가 화면을 잠그고 30초 이상 기다린 뒤 잠금을 해제한다. 본문을 확인하고
   새 증거 폴더로 다시 복사해 원고 해시를 대조한다.
4. 앱 전환기에서 **전용 앱만** 위로 밀어 종료하고 앱 아이콘으로 다시 실행한다.
   본문/분할 상태와 원고 해시를 다시 확인한다.
5. 한글 IME 조합 중 잠금, 저장 실패/지연, 저장 전 종료는 별도 케이스다.
   이미 저장된 표식 보존 결과로 완료 처리하지 않는다.

기기 모델, OS 빌드, 소스 기준선과 빌드 해시, 각 단계의 관찰 주체·시각,
원고 해시를 기록한다. 잠금 시간을 기다렸다는 사실만으로 OS suspension을
직접 관찰했다고 쓰지 않는다. 네트워크가 꺼진 로컬 작품에는 전송 대기 요청이
생성되지 않을 수 있으므로, 이 흐름은 영구 큐/응답 유실 복구의 실기기 증거가 아니다.

## 실행 결과

2026-09-22: iPad Pro 11-inch (M4), iPadOS 27.0 (24A437), Xcode 27.0 (27A266a).
소스 기준선 `d791b27202482b8ab4c884f52f31213a018092e6`. 페어링과 개발자 모드를
확인했고 전용 앱/러너가 설치돼 있지 않음을 확인했다.

- 전용 앱/러너 서명·실기기 빌드: 성공. 첫 XCTest 시도에서는 러너만 설치됐고
  초기화 실패로 앱 설치까지 진행되지 않았다.
- 앱 Info.plist의 서버 URL/key: 빈 값 확인.
- 공통 계약 검증: 통과 (0.2.0, canonical SHA-256
  `416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670`).
- 첫 UI 테스트 시도: **본문 테스트 실행 전 러너 초기화 실패**.
  `Timed out while enabling automation mode.`가 발생했다. 테스트가 실행되거나
  원고 복구가 성공한 것으로 집계하지 않는다.
- 후속 앱 설치 시도: 무료 개발 프로필 설치 앱 수 한도로 실패했다. 기존 Debug와
  receiveboundary 앱은 보존하고, 이번에 새로 만든 테스트 러너만 제거했다.
  그 뒤 전용 검증 앱 설치와 debugger 없는 실행이 성공했다.
- 08:20 KST 기기 화면에서 `ChocoS 수명주기 검증`의 빈 작품 목록을 확인했다.
  현재 구성은 기존 앱을 유지하기 위해 수동 입력·잠금·종료와 컨테이너 해시 대조를
  사용한다. 자동 UI 테스트 완료는 별도 러너 슬롯/자동화 초기화 해결까지 보류한다.
- 실행 파일 SHA-256: `643dda78a27acd0bd73c7381e3069778b5bfbfab7c0ec88bbc2954c9baf921f6`.
- 제품 코드가 든 Debug dylib SHA-256:
  `5d65f831020d5d287b4685fd28c199e9f4b2b30aca4f61818b1fa091068895bd`.
- 첫 빌드에는 `Metadata extraction skipped, no AppIntents.framework dependency found`
  도구 경고 3건이 있었다. Swift 컴파일 오류는 없으며 경고 0건으로 보고하지 않는다.
- XCTest 러너는 launch-screen 관련 런타임 안내도 출력했다.
- 사용자 잠금·해제 및 수동 강제 종료·재실행 후 저장 본문/분할 화면 보존 확인.
  큐 상태는 아직 미검증. 각 단계 증거는 아래에 기록했다.

로컬 증거는 `/private/tmp/writerpad-sync004-device-build.log`,
`/private/tmp/writerpad-sync004-device-test.log`,
`/private/tmp/writerpad-device-original-derived-evidence/Logs/Test/Test-WriterPad-2026.09.22_08-17-08-+0900.xcresult`에 있다.
Xcode가 수집한 진단에는 기기 개인정보가 포함될 수 있으므로 저장소에 넣지 않는다.
초기 DerivedData 경로가 대소문자 비구분 파일시스템에서 소스 worktree와 겹쳤다.
생성된 `Build`, `Logs`, 캐시 폴더와 `info.plist`는 삭제 없이
`/private/tmp/writerpad-device-original-derived-evidence`로 옮겼다. 소스 변경이
아니며 stage하지 않는다. 이동 전 로그의 내부 경로는 원래 위치를 가리킨다.
검증 중간 상태의 코드/문서는 아직 커밋·병합하지 않았다.

### 수동 입력 후 잠금 전 기준 (08:23 KST)

사용자가 생성 원고 입력 완료를 알린 뒤 전용 앱의 `Documents`만 복사했다.
기기 화면에서 왼쪽 001화·오른쪽 002화 분할과 두 한글 문구를 확인했다.
복사한 TXT의 UTF-8 바이트가 기대 본문과 정확히 일치하며 BOM/끝 개행은 없다.
이는 이미 영구화된 본문의 기준 증거이며, IME 조합 상태나 비활성 진입 중
저장 완료를 증명하지 않는다.

| 원고 | 본문 | UTF-8 바이트 | SHA-256 |
|---|---|---:|---|
| 001화 | 왼쪽 저장 확인 | 20 | `c727dc917909a0f13069d7d08eefa8bbe89c8bd51bc4fe50b31c4650c7d008d5` |
| 002화 | 오른쪽 저장 확인 | 23 | `70c2a94d644e2091e7f50ea4543b093ece3bd2b9eca4e9c10794f0bfa4cd1a22` |

기준 복사본: `/private/tmp/writerpad-lifecycle-before-lock-20260922`.
화면 증거: `/private/tmp/writerpad-lifecycle-before-lock-20260922.png`.
원본 앱 파일은 변경하지 않았다. 다음은 사용자 화면 잠금 30초 이상·해제 후
동일 원고 해시 대조이며, 강제 종료는 그 다음에 별도로 진행한다.

### 잠금·해제 후 대조 (08:31 KST)

사용자가 30초 이상 잠금·해제 절차를 요청받은 뒤 `잠금 해제 완료`라고 보고했다.
잠금 동작과 지속 시간은 직접 측정하지 않았다. 해제 후 도구는
`passcodeRequired: false`, `unlockedSinceBoot: true`를 반환했다.

- 전용 앱의 `Documents`를 `/private/tmp/writerpad-lifecycle-after-lock-20260922`로
  새로 복사했다. 잠금 전 복사본과 `diff -rq` 대조 결과 차이가 없었다.
- 001화 20바이트, 002화 23바이트이며 두 SHA-256 모두 잠금 전 표와 동일하다.
- `/private/tmp/writerpad-lifecycle-after-lock-20260922.png`에서 좌우 분할,
  001화/002화 본문과 오른쪽 활성 상태가 유지된 것을 확인했다.
- 판정: 이번 수동 잠금·해제 흐름 이후 **이미 저장된 두 합성 본문과 화면 상태 보존**.
  OS suspension 직접 관찰, 잠금 중 저장/전송 완료, 미영구화 IME 입력 복구로
  확대 해석하지 않는다. 다음은 전용 앱의 수동 강제 종료·아이콘 재실행이다.

### 수동 강제 종료·재실행 후 대조 (08:33 KST)

사용자에게 앱 전환기에서 전용 앱만 종료하고 아이콘으로 다시 실행하도록
요청했고, 사용자가 `재실행완료`라고 보고했다. 종료 동작은 사용자 보고이며
종료 전후 PID나 종료 순간 자체를 도구로 기록하지는 않았다.

- 전용 앱의 `Documents`를 `/private/tmp/writerpad-lifecycle-after-relaunch-20260922`로
  복사했다. 잠금 전 기준 복사본과 재귀 대조한 결과 파일 내용/구성 차이가 없었다.
- 001화 20바이트, 002화 23바이트와 두 SHA-256이 잠금 전·후 값과 모두 일치했다.
- `/private/tmp/writerpad-lifecycle-after-relaunch-20260922.png`에서 좌우 분할,
  두 원고 본문과 오른쪽 활성 상태가 복원된 것을 확인했다. 바인더 행 선택 강조와
  저장 표시 아이콘까지 모든 UI가 동일하다는 판정은 아니다.
- 판정: 이번 생성 원고 2개의 **영구 저장 후 수동 잠금·재실행 보존 검사 통과**.
  서버 송신, 영구 큐 재개, 응답 유실, 저장 직전 강제 종료, 조합 중 입력 보존 및
  OS suspension 직접 관찰은 이번 실기기 검사의 범위 밖이다.

수동 검사 통과만으로 SYNC-004 전체 완료나 자동 UI 테스트 통과를 선언하지 않는다.

## 빌드 경고와 자동 검증 제약 정리

앱·단위 테스트·UI 테스트 타깃에는 App Intents/Shortcuts 선언이나 프레임워크
의존성이 없다. `Shared.xcconfig`의 `LM_SKIP_METADATA_EXTRACTION = YES`로
이 타깃들에 불필요한 메타데이터 추출 작업을 생성하지 않도록 했다.
일반 Swift 경고 억제나 로그 필터는 추가하지 않았다. 패키지 의존성의 빌드 설정도
변경하지 않는다. App Intents/Shortcuts를 도입하면 이 opt-out을 제거해야 한다.
작업 생성 조건은 [Swift Build 원본](https://github.com/swiftlang/swift-build/blob/1317b101ee61a827fc1689e9ee880085d9fc89cd/Sources/SWBApplePlatform/AppIntentsMetadataTaskProducer.swift#L55)에 근거한다.

XCTest의 launch-screen 안내는 Xcode가 제공한 러너 앱에서 발생한 별도 런타임
메시지다. 제품 앱에는 기존 `UILaunchScreen` 생성 설정이 있다. 이 안내를 없애려고
Xcode 제공 실행 파일/러너 Info.plist를 사후 수정하지 않는다. 실기기 UI 자동화
초기화 시간 초과와 프로필 설치 슬롯 제한도 해결됐다고 주장하지 않는다.

재검증은 별도 DerivedData `/private/tmp/writerpad-device-validation-dd`와
새 `WriterPad-Lifecycle-Isolated` 시뮬레이터(iOS 27.0, iPad Pro 11-inch M5,
`5C09EFE4-0C1C-4B98-A101-B7597EF8BA6E`)를 사용한다. 실기기 앱은 재설치하지
않으므로 위 수동 검사의 빌드 해시와 생성 원고는 그대로 남는다.

- iPadOS 새 `build-for-testing` 및 이어서 개발 프로필 서명 빌드: 성공.
  두 로그 모두 `warning:`/`error:` 0건, 제품/테스트 타깃의
  `ExtractAppIntentsMetadata` 작업이 생성되지 않음을 확인했다.
  로그: `/private/tmp/writerpad-device-warning-fixed-build.log`,
  `/private/tmp/writerpad-device-warning-fixed-signed.log`.
- 공통 계약 검증과 `git diff --check`, Xcode 프로젝트 plist 문법 검사: 통과.

## 자동 UI 검사에서 확인한 표시 결함 — 최초 실패 기록

아래는 수정 전 자동 검사 **미통과** 기록이다. 당시 worktree는 커밋·병합하지 않았다.

- iOS 27.0: `testEmptyRightPaneCanTakeActivationWithoutBlockingWorkspaceTouches`
  실행 중 `App animations complete notification not received`와 60초 대기가
  반복돼 실행을 중단했다. xcresult는 `Testing was canceled`로 실패 1건,
  통과 0건을 기록했다. 제품 assertion 실패나 나머지 두 검사 통과로 해석하지 않는다.
  로그: `/private/tmp/writerpad-lifecycle-simulator-ui.log`.
- iOS 26.5 (23F77), iPad Pro 11-inch M5, 시뮬레이터
  `D64B9A09-CAA0-4EEE-88DE-1E17088CD06F`: 동일 빌드에서 새 수명주기 검사가
  실행됐으나 왼쪽 본문 비교가 실패했다. 최초 실행과 실제 값 진단 실행,
  활성화 후 재검사 실행 모두 같은 빈 본문으로 실패했다.
- 합성 작품 `Lifecycle Synthetic 4CD74C3C`의 저장 TXT에는
  `LEFT-4CD74C3C-saved-before-home`과 `RIGHT-4CD74C3C-saved-before-home`이
  각각 정확히 남아 있었다. UI 진단에서도 왼쪽 프레임의 값은 빈 문자열,
  오른쪽 프레임의 값은 기대 본문이었다. 순서가 뒤바뀐 문제가 아니었다.
- 최초 실패 영상의 35초 프레임에서, 홈 전환 **이전**부터 왼쪽 001화가
  31자 표시와 달리 빈 문서 placeholder를 보여 준다. 47초의 홈 복귀 후 프레임도
  같다. 따라서 접근성만의 문제나 홈 복귀에만 한정된 문제로 처리하지 않는다.
- 편집기를 활성화해 검사하는 시도도 실패했다. 해당 임시 우회는 제거했고
  최종 테스트는 원래 본문 기대값을 유지하며 홈 전환 전 검사도 수행한다.
- 조사 후보는 분할 레이아웃 변경 때 native text view 재생성과 외부 스냅샷
  적용 경계다(`UIKitTextViewBridge.swift`, `WritingWorkspaceView.swift`).
  근본 원인은 아직 확정하지 않았으며 제품 코드 수정은 하지 않았다.

최초 실패 결과는
`/private/tmp/WriterPad-Sync004/Logs/Test/Test-WriterPad-2026.09.22_08-55-50-+0900.xcresult`,
추출한 첨부는 `/private/tmp/writerpad-ui265-all-attachments`에 있다.
영상 프레임은 `/private/tmp/writerpad-ui265-before-home.png`와
`/private/tmp/writerpad-ui265-before-assertion.png`다. 이후 로그는
`/private/tmp/writerpad-lifecycle-ui-value-diagnostic.log`와
`/private/tmp/writerpad-lifecycle-ui-focused.log`에 있다.
최초 실패 뒤 장시간 대기한 `simctl diagnose`만 종료했으므로 상세 시스템
진단은 일부만 수집됐다. 테스트의 assertion 실패와 화면/접근성 첨부는 보존했다.

이 흐름은 왼쪽에 먼저 입력하고 나서 분할을 연다. 앞선 실기기 수동 검사는
좌우 분할을 먼저 준비한 뒤 입력했으므로, 그 성공 결과로 이번 재현을 부정하지 않는다.
다음 단계는 표시 결함의 최소 회귀 테스트·수정과 UI 재검증이다.

### 홈 전환 전 assertion으로 최종 재현 (09:08 KST)

홈 전환 전 본문 비교를 추가한 최종 테스트도 44.714초에 실패했다.
실행 1건, 실패 1건, 통과 0건이며 다음 메시지로 분할 이후·홈 전환 이전의
빈 왼쪽 본문을 직접 확인했다.

```text
before home: expected LEFT-A4B5FB40-saved-before-home; actual Optional()
```

로그: `/private/tmp/writerpad-lifecycle-ui-before-home-red.log`.
결과: `/private/tmp/WriterPad-Sync004/Logs/Test/Test-WriterPad-2026.09.22_09-07-35-+0900.xcresult`.
빌드 경고는 0건이고 xcresult의 runtimeWarnings는 비어 있다. assertion 실패는
그대로 보존했으며 홈 복귀·재실행 검사는 이 선행 실패 때문에 실행되지 않았다.
후속 진단 실행의 `-collect-test-diagnostics never`는 장시간 시스템 진단만
비활성화한다. 테스트 assertion, 로그와 화면 첨부를 통과 처리하거나 제거하지 않는다.

## 표시 결함 원인과 수정 (2026-09-22 후속 단계)

원인은 coordinator 재사용이 아니라 전체 본문을 읽는 출처였다.
`EditorSessionModel.applyTextMutation`은 최신 `textBuffer`를 갱신하고,
입력마다 큰 String을 만들지 않기 위해 `@Published text`에는 게시하지 않는다.
기존 workspace Binding은 `model.text`를 읽었다. 분할의 조건부 뷰 전환으로
새 native view가 생성되면 초기화에 오래된 게시 문자열(이번 재현에서는 빈 문자열)을
적용했다. 버퍼 기반 글자 수와 TXT 저장이 정상인 이유도 이 경계 차이로 설명된다.

- `iPadTextEditor.externalTextSnapshot` 지연 공급자를 추가하고 workspace에서
  `{ model.currentText }`를 전달한다. 새 native view 초기화와 전체 본문 복구에만
  최신 문자열을 읽는다. 공급자를 쓰지 않는 기존 호출자는 Binding 경로를 유지한다.
- 동일 문서/버전 갱신과 UTF-16 길이가 제공된 연속 delta 적용은 스냅샷을 만들지
  않는다. 버전을 건너뛰거나 잘못된 delta 범위를 받으면 최신 본문으로 복구한다.
- 단위 회귀 2개를 먼저 추가하고 공급자를 사용하지 않는 코드에서 실패를 확인했다.
  `/private/tmp/writerpad-split-snapshot-unit-red.log` 및
  `/private/tmp/WriterPad-Sync004/Logs/Test/Test-WriterPad-2026.09.22_09-21-40-+0900.xcresult`:
  테스트 2개 실패(본문·복사 횟수 assertion 실패 합계 13건).
- 수정 후 `AppEnvironmentTests` 116개가 실패·건너뛰기 없이 통과했다.
  새 회귀는 입력 뒤 재생성된 편집기의 한글·이모지·줄바꿈 본문, 지연 스냅샷 호출 횟수,
  동일 버전 재적용 방지, 연속 delta 적용, 버전 건너뛰기와 잘못된 범위 복구를 검사한다.
  기존 IME·Undo·읽기 전용·포커스·저장 전환 검사도 함께 실행했다.

### 수정 후 최종 결과 (09:26 KST 이후)

- iOS 26.5 동일 전용 시뮬레이터에서 단위 116개 + UI 3개, **119개 통과**.
  실패 0, 건너뛰기 0, xcresult `runtimeWarnings: []`, 빌드 경고 0건.
  UI 검사는 빈 오른쪽 패널 활성화/검색, 입력 후 분할·홈 복귀·재실행 본문 보존,
  분할 닫기/재개 활성 패널 및 회전 동작이다. 수명주기 검사의 기대값을 완화하지 않았다.
- 본문 fixture는 `Lifecycle Synthetic 0B316044`,
  `LEFT-0B316044-saved-before-home` / `RIGHT-0B316044-saved-before-home`이다.
  분할 후 홈 전환 전, 홈 복귀 후, 앱 재실행 후의 좌우 본문 전체 값과 오른쪽 활성
  상태가 모두 일치했다. XCTest의 종료·실행이며 사용자 강제 종료/OS suspension과는 다르다.
- 로그: `/private/tmp/writerpad-split-snapshot-regression.log`.
  결과: `/private/tmp/WriterPad-Sync004/Logs/Test/Test-WriterPad-2026.09.22_09-23-19-+0900.xcresult`.
  본문 기대값과 세 시점의 화면 첨부: `/private/tmp/writerpad-split-snapshot-ui-evidence`.
  화면에서도 왼쪽 본문이 실제 표시되는 것을 확인했다. 앱 screenshot에는 상단 검은 영역과
  오른쪽 잘림이 있어 전체 레이아웃 품질의 근거로 삼지 않는다. 양쪽 전체 본문 일치는
  각 native text view의 정확한 값 비교 assertion으로 확인했다.
- 실제 iPad 설치 없이 기존 개발 프로필로 iPadOS `build-for-testing` 서명 빌드 성공.
  `/private/tmp/writerpad-split-snapshot-device-signed.log`: 빌드 경고·오류 0건.
  기존 실기기에 설치된 검증 앱은 앞선 수동 검사 빌드 그대로이며 원고도 변경하지 않았다.
- 공통 계약 검증, `git diff --check`, Xcode 프로젝트 plist 검사도 통과했다.
  계약 canonical SHA-256은 `416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670`로 동일하다.

위 자동 검증 종료 시점에는 아직 커밋·병합하지 않았다. 이후 커밋·설치는 아래 기록을 따른다.
iOS 27 자동화 지연, 미영구화 IME 입력, 전송 중 중단,
영구 큐 재개·응답 유실, OS suspension 직접 관찰은 이번 결과로 완료 처리하지 않는다.

## 변경 검토·커밋과 실기기 업데이트 (2026-09-22 09:33 KST)

- 지연 공급자의 호출 경계, 기존 Binding fallback, 문서/버전 판정과 IME·Undo 경계를
  재검토했고 추가 수정이 필요한 문제를 찾지 못했다. 테스트·서명 빌드 이후 제품 코드는
  변경하지 않았다. `git diff --check`도 통과했다.
- 코드·테스트·빌드 설정·검증 기록을 `72ee8b858e6238a38fe44f132348a9efa1b203cb`
  (`fix: restore latest editor buffer when reopening split views`)에 커밋했다.
  원격 push·PR·병합은 하지 않았다.
- 검증 대상 iPad Pro 11-inch (M4)의 연결과 잠금 해제를 확인했다.
  실제 기기 UDID는 공개 기록에서 제외한다.
  설치 전 Documents를 `/private/tmp/writerpad-lifecycle-before-snapshot-fix-20260922`로
  보관했다. 앞선 수동 재실행 사본과 비교하면 자동 백업 파일 4개만 추가됐고,
  기존 원고 파일 내용은 동일했다.
- 기존 개발 프로필로 서명한 `com.chocos.writerpad.lifecyclevalidation`만 업데이트했다.
  서버 URL/key가 비어 있음을 확인했으며 Debug·Receive Boundary 앱은 변경/삭제하지 않았다.
  별도 XCTest 러너 설치도 시도하지 않았다.
- 설치한 산출물의 SHA-256:
  실행 파일 `89689435c3f991e37b2be95006303122592993534a1757d8c5326144b245eddb`,
  제품 Debug dylib `3ae0564a7a3530d344f4e7d95271db4a9ab33c37fef594edf12d94b539c6082f`.
- 디버거 없이 앱을 실행한 뒤 Documents를
  `/private/tmp/writerpad-lifecycle-after-snapshot-fix-install-20260922`로 복사했다.
  설치 직전 사본과 `diff -rq` 차이가 없었다. 001·002화 SHA-256도 기존 표와 일치했다.
- 화면 `/private/tmp/writerpad-lifecycle-snapshot-fix-installed-20260922.png`에는
  좌우 모두 001화와 `왼쪽 저장 확인`이 표시됐다. 이는 현재 화면 관찰이며,
  이전 수동 검사의 001·002화 배치 복원을 확인했다는 뜻은 아니다.

다음 사용자 절차는 기존 001·002화를 보존하면서 빈 003·004화를 사용한다.
왼쪽 제목을 눌러 활성화하고 분할을 닫은 뒤 003화에 `분할 전 입력 확인`을 입력한다.
그 뒤 분할을 다시 열어 왼쪽 본문이 남는지 확인하고 오른쪽에 004화를 선택해
`오른쪽 새 입력 확인`을 입력한다. 설치 직후에는 이 입력 완료 보고를 기다렸다.
입력 이후 결과는 아래 기록을 따른다.

### 수정 빌드 입력·분할 확인 (2026-09-22 10:50 KST)

사용자가 `입력 완료`라고 보고했다. 입력·분할 조작 순서 자체는 사용자 보고이며,
도구는 완료 후 화면과 저장 파일을 직접 확인했다.

- 화면 `/private/tmp/writerpad-lifecycle-snapshot-fix-input-20260922.png`에서
  왼쪽 003화의 `분할 전 입력 확인`(10자), 오른쪽 004화의
  `오른쪽 새 입력 확인`(11자), 오른쪽 활성 상태를 확인했다.
  이전 결함의 빈 왼쪽 placeholder가 아니라 실제 본문이 표시됐다.
- Documents 사본은 `/private/tmp/writerpad-lifecycle-snapshot-fix-input-20260922`에
  보관했다. 네 원고 모두 기대 문자열을 UTF-8로 변환한 바이트와 정확히 같았고,
  BOM이나 끝 개행도 추가되지 않았다.
- 003화: 24바이트, SHA-256
  `b1a056e6531a220b9eab45f6d31b37acb511d52f9ccf84323da8fec572c22195`.
- 004화: 27바이트, SHA-256
  `ffa6740d1773fada609db868abd9ed0c7944869f1ba31b96eaa13db20eec617f`.
- 001화(20바이트)·002화(23바이트)의 내용과 SHA-256은 기존 기준과 동일하다.
  설치 후 사본과 전체 비교하면 003·004화 본문 변경 및 자동 백업 파일 8개 추가만 있다.
- 판정: 사용자 수행 입력·분할 흐름 이후 **수정 빌드의 좌우 본문 표시·저장 확인 통과**.
  새 빌드에서 잠금·강제 종료·재실행까지 통과한 것으로 확대하지 않는다.

이 사본을 다음 수명주기 검사의 기준으로 사용한다. 사용자에게 현재 003·004화를
유지한 채 30초 이상 잠금·해제하고 앱으로 돌아오도록 요청했다. 본문 수정과 강제
종료는 아직 하지 않도록 안내했다. 이후 새 화면·사본을 받아 단계별로 대조한다.

### 수정 빌드 잠금·해제 후 대조 (2026-09-22 10:53 KST)

사용자가 30초 이상 잠금·해제 요청 후 `잠금 해제 완료`라고 보고했다.
잠금 동작과 지속 시간은 직접 측정하지 않았다. 기기는 `passcodeRequired: false`,
`unlockedSinceBoot: true`를 반환했다.

- `/private/tmp/writerpad-lifecycle-snapshot-fix-after-lock-20260922.png`에서
  003화·004화의 두 본문, 글자 수 10자·11자와 오른쪽 활성 상태가 유지됨을 확인했다.
- Documents를 `/private/tmp/writerpad-lifecycle-snapshot-fix-after-lock-20260922`로
  새로 복사했다. 입력 완료 시점의 사본과 `diff -rq` 차이가 없었다.
- 001·002화의 기존 해시와 003·004화의 위 SHA-256이 모두 일치했다.
- 판정: 수정 빌드의 **이미 저장된 본문·분할 상태의 사용자 잠금·해제 후 보존 통과**.
  미영구화 IME 입력 복구, 잠금 중 저장·서버 송신 완료, OS suspension 직접 관찰은
  검증하지 않았다.
- 다음 수동 종료 전에 전용 앱 설치 경로의 PID `1237`을 관찰했다.
  설치 컨테이너 식별자는 공개 기록에서 제외한다. 다른 WriterPad 프로세스는 건드리지 않았다.

사용자에게 앱 전환기에서 `ChocoS 수명주기 검증`만 종료한 뒤 앱 아이콘으로
다시 실행하도록 요청했다. 본문은 수정하지 않고 003·004화가 복원되는지 확인한다.
이 요청에 대한 재실행 후 결과는 아래에 기록한다.

### 수정 빌드 수동 종료·재실행 후 대조 (2026-09-22 10:55 KST)

사용자가 `재실행 완료`라고 보고했다. 앱 전환기 종료와 아이콘 실행 동작은 사용자
보고이며, 도구는 실행 후 화면·저장 파일과 프로세스를 직접 관찰했다.

- 동일 전용 앱 설치 경로의 PID가 종료 전 `1237`에서 `1321`로 바뀌었다.
  새 프로세스 실행은 확인했지만 이 값만으로 종료 원인이나 정확한 시점을 단정하지 않는다.
- `/private/tmp/writerpad-lifecycle-snapshot-fix-after-relaunch-20260922.png`에서
  왼쪽 003화·오른쪽 004화 본문, 글자 수 10자·11자, 분할과 오른쪽 활성 상태를 확인했다.
  바인더 행 선택 강조와 저장 아이콘까지 이전 화면과 동일하다고 판정하지는 않는다.
- Documents를 `/private/tmp/writerpad-lifecycle-snapshot-fix-after-relaunch-20260922`로
  복사했다. 입력 완료 기준 사본과 `diff -rq` 차이가 없었다. 잠금 후 사본 역시
  같은 기준과 동일했으므로 세 시점의 파일 구성·내용이 같다.
- 001~004화의 SHA-256이 모두 입력 완료 기준과 일치했다. 이전 보관 사본과
  기기의 원고를 삭제하거나 덮어쓰지 않았다.
- 판정: 수정 빌드에서 **이미 저장된 두 합성 본문과 분할·활성 패널의 사용자 잠금·
  수동 재실행 보존 검사 통과**, 기존 001·002화도 보존.

이번 실기기 검증에는 추가 사용자 조작이 필요하지 않다. 다음은 변경 최종 검토·PR 준비다.
제품 코드는 `72ee8b8` 이후 변경하지 않았다. 원격 push·PR 생성·병합은 하지 않았다.
서버 송신·영구 큐 재개·응답 유실·저장 직전 종료·미확정 IME 입력과 OS suspension
직접 관찰은 여전히 별도 검증 범위이므로 SYNC-004 전체 완료로 처리하지 않는다.
