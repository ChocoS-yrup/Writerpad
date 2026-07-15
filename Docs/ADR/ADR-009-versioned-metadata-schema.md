# ADR-009: 버전된 SwiftData 메타데이터 스키마와 원고 분리

- 상태: 승인
- 날짜: 2026-07-15

## 맥락

앱 재실행 후 작품·문서 정체성과 화면 상태를 복원해야 하지만 SwiftData 손상이나 마이그레이션 실패가 원고 TXT 손실로 이어지면 안 된다. Windows v2 서버 revision 구조도 아직 확정되지 않았다.

## 결정

- 최초 스키마는 `WriterPadSchemaV1` 1.0.0으로 명시한다.
- 작품, 문서, 전역 앱 상태, 작품별 화면 상태를 별도 레코드로 저장한다.
- 프로젝트·문서·작품별 화면 상태의 UUID에는 unique 제약을 둔다.
- 원고 본문, 서버 revision, metadata revision, operation payload는 저장하지 않는다.
- 모든 접근과 도메인 변환은 `SwiftDataMetadataRepository` actor에서 수행한다.
- 손상 레코드는 기본값으로 조용히 덮지 않고 명시적 오류로 반환한다.

## 결과

메타데이터 저장소를 닫았다 다시 열어도 UUID와 화면 상태를 복원할 수 있다. 메타데이터 복구가 필요해도 TXT를 수정하지 않고 후속 재스캔 경로를 사용할 수 있다. 다음 스키마는 V1을 유지한 채 migration stage를 추가해야 한다.
