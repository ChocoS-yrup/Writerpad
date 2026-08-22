# ConflictRecoveryStore 서버 CI 기준선 예외

작성일: 2026-08-22
구현 시작 기준 HEAD: `a53398da5c88f27a2dc558019a1d920c9294745b`

## 승인 범위

이 예외는 iPad의 로컬 `ConflictRecoveryStore` 구현과 시험에만 적용한다.
계약 핸드셰이크 활성화 승인이 아니며 다음 영역은 계속 동결한다.

- `sync-contract/`
- 서버 계약 핀
- 서버 migration 및 RPC
- 계약 핸드셰이크와 capability 선언

## 기준선 증거

- 일반 계약 CI: <https://github.com/ChocoS-yrup/Writerpad/actions/runs/32547893945>
  - Ubuntu, Windows, PR merge 통과
- 서버 계약 CI: <https://github.com/ChocoS-yrup/Writerpad/actions/runs/32547894035>
  - 서버 시험 실행 전 `0.3.0`과 보호된 `0.2.0` 핀 불일치로 중단

위 서버 CI 결과는 통과가 아니라 기존 기준선 실패로 기록한다. 허용되는 실패는
위와 완전히 동일한 핀 불일치뿐이다. 다른 오류가 추가되거나 핀 검사를 통과한 뒤
다른 단계에서 실패하면 개발을 중단하고 원인을 보고한다.

## 구현 후 관문

- 관련 시험과 전체 iPad 시험 통과
- 일반 계약 CI 통과
- 동결 경로 변경 없음
- 최종 iPad HEAD로 검증06·07 재검증
- 검증07에서 백업 생성, 원본 작업 종료, 사용자 명령 기반 복구 및 새 UUID 동기화 확인
- operation state divergence, lineage divergence, orphan 모두 0건
