# WriterPad

iPad 집필 앱. SwiftUI + SwiftData, 원고는 TXT 파일이 정본이고 Supabase로
동기화한다(Sync V2). Windows 클라이언트와 계약(`sync-contract/`)을 공유한다.

## 테스트

```
Scripts/run_tests.sh                        전체 단위 테스트
Scripts/run_tests.sh SyncV2StoreTests       한 클래스
Scripts/run_tests.sh SyncV2StoreTests/testX 한 시험
```

`xcodebuild test`를 직접 부르지 말고 이 스크립트를 쓴다. 세 가지를 빠뜨리면
실행이 조용히 망가진다.

- **시뮬레이터가 죽어 있으면 `xcodebuild`는 실패하지 않고 무한히 기다린다.**
  실제로 18분간 아무 출력 없이 멈춘 적이 있다. 스크립트가 부팅을 확인한다.
- **테스트 타임아웃이 꺼져 있으면** 매달린 시험 하나가 전체를 세운다.
  스크립트가 `-test-timeouts-enabled YES`를 켠다.
- **측정 harness는 평소 실행에서 빼야 한다.** fixture 생성만으로도 실기기에서
  52초가 걸린다. 스크립트가 건너뛴다.

진행 상황을 확인할 때는 통과 개수가 아니라 **로그 파일의 마지막 기록 시각**을
본다. 개수만 보면 멈춘 실행을 진행 중으로 오인한다.

### Release 구성으로는 테스트가 빌드되지 않는다

앱 타깃의 시험용 후크 몇 개가 `#if DEBUG` 안에 있다
(`EditorSessionModel.awaitStatisticsForTesting`,
`SupabaseAuthService.installRestoreCompletionProbe`). `ENABLE_TESTABILITY=YES`를
넘겨도 해결되지 않는다. `Docs/PerformanceBaseline.md`의 Release 측정 절차는
현재 코드에서 그대로 재현되지 않는다.

### 명시적으로 켜야 실행되는 시험

| 인자 | 대상 |
|---|---|
| `-WriterPadPerformanceBaseline` | `LocalPerformanceBaselineTests` |
| `-WriterPadPullLoopMeasurement` | `SyncV2PullLoopScalingMeasurementTests` |
| `-WriterPadAllowSimulatorCalibration` | 위 둘을 시뮬레이터에서 (교정용) |

시뮬레이터 수치는 성능 기준선으로 기록하지 않는다. 실기기 값만 쓴다.

## 새 파일은 pbxproj에 직접 등록한다

이 프로젝트는 파일 시스템 동기화 그룹을 쓰지 않는다. 새 `.swift` 파일은
`WriterPad.xcodeproj/project.pbxproj`의 **네 곳**에 넣어야 한다.

1. `PBXBuildFile` 항목
2. `PBXFileReference` 항목
3. 그룹의 `children` 목록
4. 타깃의 `Sources` 빌드 단계

등록하지 않으면 오류 없이 컴파일에서 빠진다. 기존 항목의 ID 패턴
(`A9…` 빌드, `B9…` 참조)을 따라 쓰이지 않은 번호를 쓴다.

## 구성과 번들 ID

| 구성 | 번들 ID | 홈 화면 이름 |
|---|---|---|
| Release | `com.chocos.writerpad` | ChocoS |
| Debug | `com.chocos.writerpad.debug` | ChocoS Debug |

**Debug는 별개 앱이다.** 컨테이너가 갈려 있어 실사용 앱의 원고·로그인에
영향을 주지 않는다. 대신 Debug 빌드를 새로 설치해도 그 컨테이너의 로그인과
작품은 유지된다. 자세한 이유는 `Configuration/README.md`.

Supabase URL·키는 `Configuration/Supabase.*.local.xcconfig`에만 둔다(Git 제외).

## 실기기

```
xcrun devicectl list devices
xcrun devicectl device install app --device <id> <path>/WriterPad.app
xcrun devicectl device process launch --device <id> --console \
    --environment-variables '{"OS_ACTIVITY_DT_MODE":"YES"}' com.chocos.writerpad.debug
```

- **`--console`은 앱이 종료될 때까지 반환하지 않는다.** 시작하면 반드시 중단까지
  한 쌍으로 다룬다. 방치하면 한 시간이고 붙어 있는다.
- **같은 앱에 `--console` 세션을 두 개 붙이면 서로 막혀 둘 다 멈춘다.**
  새로 붙이기 전에 기존 세션을 먼저 끊는다.
- **기기 빌드와 시뮬레이터 테스트를 동시에 돌리지 않는다.** `derivedDataPath`도
  동시 실행끼리 공유하지 않는다.
- 기기가 잠겨 있으면 `process launch`가 출력 없이 대기한다. 잠금을 먼저 푼다.

## 진단 로그

`Logger(subsystem: "com.chocos.writerpad", category: "sync-v2")`. Console.app에서
`event=` 접두 구조적 로그로 본다.

`SyncV2PullDiagnostics`(단계별 `event=pullTrace`)는 `#if DEBUG`에서만 남는다.
Release 빌드로는 아무것도 안 나온다.

## 관례

- 주석과 커밋 메시지는 한국어. 주석은 **무엇이 아니라 왜**를 적는다.
- 커밋 접두사: `fix:` `perf:` `test:` `chore:`
- 원고 본문과 경로는 로그에 남기지 않는다. 계약이 정한 숨은 문서
  (`__antigravity__/…`)의 고정 경로는 예외로 남긴다.
- 동기화 경로를 고칠 때는 "모르면 안전한 쪽"으로 답한다. 판정을 구현하지 않은
  대역이나 조회 실패는 예전 동작으로 떨어지게 둔다.
