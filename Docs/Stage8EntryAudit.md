# 8-1 기준선 동결과 진입 감사

- 감사일: 2026-07-26
- 범위: 1~7단계 로컬 제품 기준선과 8단계 진입 경계
- 직전 Git 기준: `14e7b10 feat: add transactional binder commands`
- 동결 기준: 이 문서를 포함하는 `stage7-local-baseline-2026-07-26` 태그

## 결론

1~7단계 로컬 제품은 서버 구현 없이 동작하는 상태다. `WriterPadSchemaV1`
1.0.0은 로컬 메타데이터만 저장하고, 앱 조립부는
`NoOpFutureChangeNotifier`를 사용한다. 로컬 TXT 저장 성공은 미래 변경 통지와
분리되어 있다.

8-1 감사 중 제품 코드를 변경할 회귀는 발견하지 않았다. 다만 전체 UI 테스트의
일부가 다른 테스트가 남긴 "마지막 작품 자동 열기" 설정에 의존해, 새 앱
컨테이너의 알파벳순 실행에서 작품 목록 대신 이전 작업 공간으로 진입하는
테스트 격리 결함을 확인했다. 모든 UI 테스트가 공통 생성 헬퍼를 통해 시작
설정을 명시하도록 수정했다. 제품의 사용자 설정 기본값과 실행 동작은 바꾸지
않았다. 함께 드러난 비동기 바인더 토글 대기, 분할 편집기의 활성 칸 판정,
실제 자동 치환 문자(`⋯`)와 다른 기대값도 제품 계약에 맞게 테스트만 바로잡았다.

## 확인한 저장·호출 경계

| 경계 | 현재 책임 | 서버 상태 |
|---|---|---|
| `WriterPadMetadataSchema.swift` | 작품·문서 정체성, 상대 경로, 해시, 휴지통·커서·작업 공간 상태 | server revision, base, operation, lease 없음 |
| `LocalDocumentStore` | UTF-8 TXT 원자 저장 후 SwiftData 메타데이터 반영 | 네트워크와 독립 |
| `EditorSessionModel` | 편집 버퍼, 800ms 자동 저장, 저장 성공 뒤 의미 사건 통지와 로컬 백업 | `revision`은 편집 버퍼 revision이며 서버 revision이 아님 |
| `LocalBinderCommandService*` | 생성·이름 변경·이동·순서·휴지통 거래와 복구 저널 | 완료된 일부 로컬 사건만 no-op 통지 |
| `LocalBackupStore`·`DocumentRestoreCoordinator` | 로컬 복구 스냅샷, diff·복원 | 서버 version 저장소와 분리 |
| `WorkspaceStorageCoordinator`·`EditorSessionModel` | 좌우 문서·활성 칸·커서 복원, 전환 전 저장 | lease 없음 |
| `AppEnvironment` | 로컬 저장소 조립 | `NoOpFutureChangeNotifier`, `.localOnly` |

현재 `FutureChangeNotifying.record`는 오류를 반환하지 않고 rename, move,
reorder, project rename, 상대 경로와 본문 snapshot을 충분히 표현하지 않는다.
따라서 8-2 이후 계약 감사 전에는 영구 큐로 대체할 수 없다.

## 자동 검증

### 반복 가능한 정적 검사

`Scripts/audit_stage8_entry.sh`가 다음을 검사하며 통과했다.

- Xcode Swift package dependency 부재
- Supabase client, URLSession 서버 client, Keychain API 부재
- SQLite/GRDB/SyncV2Store 부재
- `WriterPadSchemaV1`의 서버 상태 필드 부재와 1.0.0 유지
- 앱 조립부의 no-op notifier와 `.localOnly` 유지

### 깨끗한 빌드·테스트

- 환경: iPad Pro 11-inch (M5) Simulator, iOS 26.5
- DerivedData: `/private/tmp/WriterPad-Stage8-1-final-20260726`
- 결과 번들: `/private/tmp/WriterPad-Stage8-1-final-20260726.xcresult`
- 결과: 246개 중 245개 통과, 1개 skip, 실패 0
- UI 테스트: 15개 통과, 실패 0
- 빌드·테스트 종료: `xcodebuild` 종료 코드 0, `** TEST SUCCEEDED **`

성능 기준선 테스트는 평상시 전체 테스트에서는 의도적으로 skip되며,
`-WriterPadPerformanceBaseline` 전용 실행과 실제 iPad 측정 결과는
`Docs/PerformanceBaseline.md`의 7단계 증거를 유지한다.

## 사용자 데이터 보존

- 저장소의 `집필모드/`는 `.gitignore`로 제외되어 있고 Git 기준선에 추가하지 않는다.
- 감사 전 결합 SHA-256:
  `8c98055be86de97c4460ccefbcb7a3756f4aab9b2dbd76b2cacdce728a322979`
- 감사 후 결합 SHA-256:
  `8c98055be86de97c4460ccefbcb7a3756f4aab9b2dbd76b2cacdce728a322979`
- 로컬 TXT, SwiftData 스키마와 저장소, 백업 형식은 8-1에서 변경하지 않았다.
- SyncV2 SQLite는 아직 생성하지 않았다.

## 실제 iPad와 Windows 차이

- 이번 8-1에서는 실제 iPad를 새로 실행하지 않았다. 최근 실제 기기 증거는
  `Docs/Stage7LocalMilestoneAudit.md`와 `Docs/PerformanceBaseline.md`의
  iPad Pro 11-inch (M4), iPadOS 26.5.2 결과다.
- Windows v2에는 UUID, server revision, operation queue, lease, pull,
  3방향 병합이 있으나 iPad에는 아직 모두 없다.
- SQL·Windows v2의 상세 계약은 8-2 범위이므로 이번 단계에서 읽거나
  구현 결론을 확장하지 않았다.

## 다음 단계 진입 조건

8-2는 다음 조건을 모두 만족한 뒤에만 시작할 수 있다.

- 이 문서를 포함한 Git 동결 태그가 존재한다.
- 깨끗한 DerivedData 전체 테스트의 통과·skip·미실행 수가 확정된다.
- 정적 진입 감사가 계속 통과한다.
- 사용자 원고 결합 SHA-256 전후 값이 같다.
- 실제 iPad 신규 검증이 없었다는 제한을 인수한다.

이 문서는 8-1에서 중단하기 위한 보고서이며 8-2 계약 감사 결과를 포함하지 않는다.
