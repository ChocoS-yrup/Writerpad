# 함수 기본 EXECUTE 보정 — 2026-09-28

## 문제와 범위

PR #48 staging 배포 후 남은 PR #27/#30 미배포 차이를 대조하다가
`20260921125202_harden_legacy_function_privileges.sql`의 기본 권한 검증 누락을 발견했다.
스키마 한정 REVOKE는 전역 기본 PUBLIC EXECUTE를 제거하지 못한다.
기존 검증은 public 스키마의 pg_default_acl만 검사하여 전역 기본값을 놓친다.

WriterPad Staging의 READ ONLY 조회에서 postgres의 유효 전역 PUBLIC EXECUTE가 true임을
확인했다. 기존 public 스키마 default ACL은 owner-only였지만 전역 기본값을 상쇄하지 못한다.
실제 작품 전환, 사용자 행 조회, DB 변경은 이 조사에서 실행하지 않았다.

[PostgreSQL 17 공식 설명](https://www.postgresql.org/docs/17/sql-alterdefaultprivileges.html)은
schema별 기본 권한이 global 기본 권한에 더해지며 schema별 REVOKE로 global 권한을
제거할 수 없음을 명시한다.

## 보정

CLI로 생성한 `20260927174805_correct_function_default_privileges.sql`이
postgres 소유의 미래 함수에 대한 PUBLIC EXECUTE를 전역에서 회수하고,
public 스키마의 명시적 PUBLIC 기본 grant도 제거한다.
pg_default_acl 행 부재 시 acldefault로 내장 기본값까지 검사한다.
기존 migration과 RPC 정의/ACL, 다른 소유자, 계약 pin은 변경하지 않는다.

이 기본값은 **postgres가 앞으로 생성하는 모든 스키마의 함수**에 영향을 준다.
다른 스키마에 별도로 지정한 grant와 다른 역할에 대한 명시적 grant는 유지한다.
새 RPC를 공개하려면 해당 migration에서 필요한 역할에 명시적으로 GRANT해야 한다.
현재 앱/Windows RPC는 이미 명시적 grant가 있어 해당 동작 변경이 없다.

## 검증

- 폐기형 PostgreSQL CI에서 새 public SECURITY DEFINER와 private SECURITY INVOKER 함수를
  생성해 anon/authenticated/service_role의 실제 EXECUTE 권한을 검사한다.
- 익명 호출 거부, owner 실행 유지, 명시적으로 부여한 authenticated 호출 성공을 검사한다.
- 기존 document/atomic 인증 실패 wrapper 및 validator 실행 권한을 검사한다.
- 기존 11개 migration만 적용한 별도 DB에서는 동일 시험이
  `NEW_FUNCTION_EXECUTE_EXPOSED`로 실패해야 한다.
- 전체 12개 migration 설치/재적용, 기존 서버·handshake·전환 회귀는 기존 CI에서 함께 실행한다.
- 로컬 Python 3.12.13 서버 정적 검사와 revalidation harness 검사는 통과했다.
- 기본 python3는 3.9.6으로 pin 검사가 실패했다. 올바른 런타임으로 다시 통과했다.
- 로컬 계약 verifier는 rfc8785 미설치로 실행되지 않았으며 CI의 pinned 설치로 검증한다.
- 로컬 Docker daemon이 없어 실제 SQL 실행은 CI 결과로 판정한다.

## 진행 경계

신규 보정은 아직 미병합·미배포다. 기존 PR #48 staging 적용은 완료 상태로 유지한다.
후속 staging 배포 후보는 PR #27 휴지통 검사, PR #30 legacy 함수 권한,
이번 기본 권한 보정의 세 변경을 함께 검토한다. 오래된 control-documents migration으로
현재 validator를 덮어쓰지 않는다. 기존 원격 이력은 보존한다.

이 변경은 기존 함수 ACL과 Windows 실행 동작을 바꾸지 않으므로 새 Windows 회신을
필수 게이트로 추가하지 않는다. PR 병합과 staging 배포는 구체적인 검토 결과를 제시한 뒤
기존 승인 경계를 따른다. 작품 전환은 사용자 지시대로 생략한다.
