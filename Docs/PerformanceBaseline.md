# 7-6 로컬 성능 기준선

- 작성일: 2026-07-26
- 목적: Supabase 연결 전 로컬 저장·검색 경계의 성능을 고정하고, 후속 서버 구현에서 같은 항목의 전후 수치를 비교한다.
- 원칙: 시뮬레이터 결과는 측정기 교정에만 사용하며 실제 iPad 결과로 보고하지 않는다.

## 통합 fixture

`LocalPerformanceBaselineTests`는 실제 원고와 분리된 테스트 앱 임시 영역에 다음 데이터를 만든 뒤 종료 시 전부 제거한다.

| 데이터 | 크기 |
|---|---:|
| 원고 권 | 40권 |
| 원고 화 | 1,000화 |
| 화당 본문 | 6,000자 |
| 일반 보조 TXT | 500개 |
| 실제 백업 메타데이터·TXT 쌍 | 5,000개 |

평소 단위 테스트에서는 이 테스트를 건너뛴다. 명시적인 `-WriterPadPerformanceBaseline` 실행 인자가 있을 때만 동작하며, 시뮬레이터는 추가로 `-WriterPadAllowSimulatorCalibration`이 있어야 한다.

측정 항목:

- 최초 프로젝트 진입에 해당하는 최상위 바인더 로딩
- 최상위 바인더 새로고침
- 원고 폴더의 40권 로딩
- 권 하나의 25화 로딩
- 6,000자 화 전환
- 6,000자 UTF-8 원자 저장
- 실제 TXT 1,500개 전체 검색
- 실제 백업 5,000개 목록
- 저장·검색 중 60Hz 메인 액터 heartbeat 최대 간격
- 현재·최고 resident memory와 바인더 메인 스레드 파일 I/O 여부

각 반복 측정은 median과 p95를 JSON 첨부 파일과 테스트 로그에 남긴다.

## Release 시뮬레이터 교정

이 표는 측정 코드가 전체 fixture를 만들고 결과를 끝까지 기록하는지 확인한 값이다. 실제 iPad 합격 판정에는 사용하지 않는다.

- 환경: iPad Pro 11-inch (M5) Simulator, iOS 26.5 (23F77), arm64
- 빌드: Release `-O`, 성능 테스트 접근에만 `ENABLE_TESTABILITY=YES`
- 실행 결과: 통과
- fixture 생성: 3.558초
- 현재 resident memory: 155.7 MiB
- 최고 resident memory: 314.4 MiB
- 바인더 메인 스레드 파일 I/O: 없음
- 검색 중 메인 액터 최대 heartbeat 간격: 18.10ms
- 저장 중 메인 액터 최대 heartbeat 간격: 18.21ms

| 항목 | 반복 | median | p95 |
|---|---:|---:|---:|
| 최초 최상위 바인더 | 1 | 94.21ms | 94.21ms |
| 최상위 바인더 새로고침 | 10 | 6.39ms | 10.17ms |
| 원고 40권 로딩 | 10 | 20.08ms | 24.27ms |
| 1권 25화 로딩 | 10 | 19.58ms | 35.78ms |
| 6,000자 화 전환 | 10 | 2.45ms | 2.86ms |
| 6,000자 원자 저장 | 10 | 4.25ms | 6.37ms |
| 실제 TXT 1,500개 전체 검색 | 5 | 3,943.97ms | 4,171.87ms |
| 실제 백업 5,000개 목록 | 5 | 454.98ms | 832.84ms |

## 실제 iPad 기준선

2026-07-26에 연결된 실제 iPad에서 전용 테스트를 실행했다.

- 기기: iPad Pro 11-inch (M4), `iPad16,3`, arm64
- 운영체제: iPadOS 26.5.2 (23F84)
- 빌드: Release `-O`, 성능 테스트 접근에만 `ENABLE_TESTABILITY=YES`
- 실행 결과: 1개 통과, 실패·건너뜀 없음
- 테스트 본체 실행: 24.938초
- fixture 생성: 3.655초
- 현재 resident memory: 161.9 MiB
- 최고 resident memory: 161.9 MiB
- 바인더 메인 스레드 파일 I/O: 없음
- 검색 중 메인 액터 최대 heartbeat 간격: 17.12ms
- 저장 중 메인 액터 최대 heartbeat 간격: 17.28ms

| 항목 | 반복 | median | p95 | 판정 |
|---|---:|---:|---:|---|
| 최초 최상위 바인더 | 1 | 12.79ms | 12.79ms | 2초 목표 충족 |
| 최상위 바인더 새로고침 | 10 | 2.79ms | 13.22ms | 즉시 반응 |
| 원고 40권 로딩 | 10 | 8.02ms | 9.93ms | 즉시 반응 |
| 1권 25화 로딩 | 10 | 8.86ms | 16.58ms | 즉시 반응 |
| 6,000자 화 전환 | 10 | 1.89ms | 4.49ms | 체감 지연 없음 |
| 6,000자 원자 저장 | 10 | 3.24ms | 4.54ms | 타이핑 유지 가능 |
| 실제 TXT 1,500개 전체 검색 | 5 | 2,644.99ms | 2,868.62ms | 검색은 약 2.6초, 메인 액터 점유 없음 |
| 실제 백업 5,000개 목록 | 5 | 578.04ms | 737.58ms | 메모리 종료 없음 |

근거:

- XCTest 결과 번들에서 기기·운영체제와 1개 테스트 통과를 다시 확인했다.
- 테스트가 원본 JSON을 XCTest 첨부 파일로 저장하며, 로그에도 같은 JSON을 남겼다.
- 60Hz heartbeat 기준으로 검색·저장 중 최대 간격이 각각 17.12ms·17.28ms여서 장시간 작업이 메인 액터를 막지 않았음을 자동 검증했다.

## Instruments 증거

같은 M4 실기기와 Release 빌드에서 fixture 생성 완료 뒤 앱 프로세스에 직접 연결해 제품 작업 구간을 별도로 기록했다.

- Time Profiler: `WriterPad-Stage7-TimeProfiler-M4-Final.trace`, 7.165초, CPU 샘플 4,354개
- Time Profiler의 `potential-hangs` 표: 250ms 이상 멈춤 0건
- 표본 스택에서 `LocalBackupStore`, SwiftData와 WriterPad 제품 작업 호출을 확인
- Allocations: `WriterPad-Stage7-Allocations-M4-Final.trace`, 9.360초
- Allocations List와 VM Tracker가 모두 기록됐고, 계측 중 resident memory는 현재 192.0 MiB·최고 193.7 MiB
- Allocations 계측 오버헤드가 포함된 메모리는 위 비계측 기준선 161.9 MiB를 대체하지 않는다.

처음 Time Profiler 시도에서 fixture 임시 파일 제거가 테스트 종료 시 메인 액터에서 실행되어 668ms 멈춤으로 잡혔다. 이 작업은 제품 동작이 아니라 측정 장치 정리였으며, cleanup을 utility detached task로 옮긴 뒤 다시 기록한 최종 trace에서는 해당 멈춤이 사라졌다. fixture 생성 자체도 최종 trace 연결 전에 끝나므로 합격 판정에는 제품 작업 구간만 포함된다.

Xcode의 광범위한 부가 진단 수집은 종료 후 `devicectl diagnose` 오류로 일부만 생성됐지만, XCTest·JSON 첨부와 위 두 개의 명시적 Instruments trace는 모두 정상 완료됐다.

기존 실기기 참고값인 단일 화 100만 자 마지막 문서 재실행 복원 약 4초는 별도 시나리오이며, 위 1,000화 기준선과 섞지 않는다.

## 병목 판단 규칙

실제 기기 수치에서 프로젝트 진입·바인더·화 전환·저장·메인 액터 반응성은 기준을 충족했다. 전체 검색의 총 완료 시간만 약 2.6초이므로 서버 검색과 합친 뒤 같은 fixture로 다시 비교한다. 현 단계에서는 검색 색인이나 전역 캐시를 추가하지 않는다.

이 기준선과 Instruments 증거를 마지막으로 7단계 로컬 마일스톤은 2026-07-26에 완료됐다.
