# ADR-004: 서버 계약 확정 보류

- 상태: 승인
- 날짜: 2026-07-15

## 배경

Windows 프로그램이 Supabase v2로 전환 중이며 최종 테이블, RPC, 인증, Base 보존 방식이 확정되지 않았다.

## 결정

1~7단계에서는 서버 payload, revision 필드, SQL, 인증, 영구 큐를 구현하지 않는다. 로컬 변경 사건을 전달할 protocol과 no-op adapter만 둔다.

## 결과

로컬 기능과 서버 기능의 결합을 줄인다. Windows v2 확정 후 protocol이 바뀔 수 있으므로 현재 경계는 작고 의미 중심으로 유지한다.
