# 실사용 동기화 연결 묶음 — PR 최종 검증

## 범위

- 기준 main: `4141059ed005408cf2899e4288433caadcf825b4` (PR #43 병합).
- 브랜치: `codex/ipad-product-sync-settings`.
- 작품별 활성화, 여러 문서의 미연결 저장 기록 재시도, 작품 전환·재로그인·저장소 재생성 후 기준 재확인을 한 묶음으로 검토한다.
- 구현 및 단계별 결과: `ipad-product-sync-settings-2026-09-27.md`,
  `ipad-product-multidocument-sync-2026-09-27.md`, `ipad-product-sync-resume-2026-09-27.md`.
- 최종 점검에서 파일 인계 기준 불일치가 기존 불확실 요청의 receipt 복구 재시도까지 막던 순서를 보완했다.

## 최종 소스 검증

관련 시뮬레이터 회귀 **537개 통과, 실패 0, 건너뜀 0**. `runtimeWarnings: []`.
테스트 로그의 컴파일 경고·오류 0건. 예상 실패를 주입한 시험의 내부 `phase=failed` 진단은 테스트 실패가 아니다.

- AppEnvironment 116, LocalDocumentStore 17, LocalDocumentStoreRecovery 3,
  ReceiveValidationPolicy 18, SyncSettingsModel 6, Dispatcher 31,
  GeneralSync 72, Handshake 135, SnapshotPull 139.
- iPad Pro 11-inch (M5), iOS 26.5 시뮬레이터, Debug 격리 테스트 구성.
- 실제 TXT·SQLite·SwiftData 구성요소를 사용하고 원격 transport는 합성 응답이다.
- 로그: `/private/tmp/writerpad-product-batch-tests-v1.log`.
- xcresult: `/private/tmp/WriterPad-RecoveryRun-Fix-DD/Logs/Test/Test-WriterPad-2026.09.27_15-37-59-+0900.xcresult`.

계약 검증은 Python 3.12와 저장소의 고정 버전 의존성으로 통과했다.
`python sync-contract/scripts/verify_contract.py`: 스키마 7개, 전이 벡터 12개,
저장 이름 벡터 15개, atomic wire 4개, document wire 7개와 canonical digest 확인.
기본 Python 3.9 및 기존 불완전 임시 캐시는 사용하지 않고 별도 임시 Python 3.12 환경으로 검증했다.

최종 Release 빌드 로그는 `/private/tmp/writerpad-product-batch-release-v1.log`다.
Release 결과와 exact-head Ubuntu/Windows·PR merge-result CI, 원격 검토 결과는 PR 본문/댓글에 기록한다.
이전 단계 Release 성공을 이 최종 소스의 완료 증거로 대체하지 않는다.

## 호환성·검토 경계

계약 0.2.0, RPC 본문, 서버 스키마·RLS, Windows 코드, 교차 플랫폼 입력, 패키지·서명 설정은 바꾸지 않았다.
계약 canonical SHA-256: `416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670`.
Windows 담당자의 별도 회신은 요청하지 않는다. 기존 Ubuntu/Windows 계약 CI는 그대로 실행한다.

Supabase 공식 인증 문서·보안 체크리스트에 맞춰 기존 인증 서비스와 인증된 transport를 유지했다.
새 관리자 인증, 사용자 편집 metadata 기반 권한, 키 노출, 서버 권한 우회는 추가하지 않았다.
문서에 기록된 과거 기기·서버 시험은 실행 지시가 아니며 이번 단계에서 재수행하지 않는다.

실기기 설치, 실제 서버 송수신, 실제 프로세스 강제 종료, 전체 자동 재개 스케줄러의 완성을 주장하지 않는다.
최종 head에서 한 번 GitHub Codex 검토를 요청하며, 지적 사항과 CI 확인 뒤 병합 여부를 판단한다.
