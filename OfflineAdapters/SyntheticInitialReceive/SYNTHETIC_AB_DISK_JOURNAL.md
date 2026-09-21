# 합성 A/B 실행 저널 영속화

2026-09-14. 독립 Swift 모듈의 합성 실행 전용 저장 경로다. 기존 앱 저장소, 실제 Windows 자료, 실제 수신 baseline과 결합하지 않는다.

## 저장·실행 경계

- 정규화된 호스트 임시 디렉터리 바로 아래 `SyntheticABJournal-<합성 UUID>/execution-journal`만 허용한다. 합성 작업 디렉터리는 비어 있거나 해당 저널 하나만 가져야 한다. 실제 local project ID를 발급하지 않는다.
- 처음 생성한 프로세스의 같은 실행 잠금 구간에서만 초기 상태를 실행할 수 있다. 새 객체/새 프로세스로 다시 연 초기 상태도 재실행하지 않는다. running/stopped/finished는 모두 추가 요청을 차단한다. 읽기는 기록 확인만 제공한다.
- 디렉터리 0700, 파일 0600, 단일 writer flock와 스레드 소유 검사, 경로·링크·inode 대조를 사용한다. 기존 약한 권한을 자동 수정하거나 기존 파일을 덮어써 초기화하지 않는다.
- owner.json은 형식과 합성 작업 경로를 결합한다. 변경 불가 record-NNN.json은 sequence/previous SHA/operation/state를 담고, head.json은 최종 sequence와 해당 원래 바이트 SHA를 가리킨다. 성공 경로는 60개 snapshot과 owner/head/lock, 총 63개 파일이다.
- 각 쓰기는 새 .pending 파일을 독점 생성하고 payload를 기록·fsync한 뒤 rename·부모 디렉터리 fsync·바이트 재읽기를 수행한다. record와 head 모두 확인한 뒤 완료로 돌아온다. claim, 요청별 reserve/start/metadata/response, local_start, finish/stop을 구분한다.
- HTTP/Auth 예산은 기존 합성 기준 14/2이며 Auth 2는 HTTP 14에 포함된다. reserve와 start 기록을 확인한 다음에만 합성 transport를 호출한다. 실패 시 차감 환불·자동 재시도·페이지 추가 요청은 없다.
- claim에 합성 실행 시각·각 시간 예산·실행 만료·합성 세션 만료·세션/boot/생명주기 세대·fixture 결합을 명시해 재시작 후 읽을 수 있다. 설정 해시를 원래 값에서 재계산하고 이후 변경을 거부한다. 이 값은 실제 승인 시간이나 실제 로그인 세션이 아니다.
- 기존 기록의 바이트·해시 연결과 허용 상태 전이를 다시 확인한다. 카운터 차감 취소, 기존 단계 삭제, binding 변경, 잘못된 완료 전이를 거부한다. 유효 응답 본문만 합성 raw로 보존하고 HTTP 오류의 raw는 저장하지 않는다.
- pending·orphan·누락·손상·외부 파일·잘못된 연결·쓰기 결과 불명확은 보존·차단한다. 유효한 마지막 기록을 읽을 수 있어도 실행을 재개하지 않는다. 일반 정책/응답 실패는 마지막 확인 상태에서 stopped를 추가하며 저장 실패 뒤에는 추정 stop을 쓰지 않는다.
- 파일당 48 MiB, 기록 파일 합계 128 MiB, sequence 최대 63으로 제한한다. snapshot을 반복 보관하므로 합계 저장 한도는 응답 자체의 32 MiB 예산보다 먼저 도달할 수 있다. 이 경우 저장 실패로 차단하며 한도를 자동 확대하거나 기록을 삭제하지 않는다.

## 검증과 한계

신규 XCTest는 임시 합성 파일과 별도 호스트 probe만 사용한다. 프로세스 종료/강제 종료 이후 재실행 차단은 전원 손실이나 실기기 파일시스템 영속성 증거가 아니다. fsync 호출 성공이 모든 하드웨어의 전원 손실 내구성을 보장한다는 뜻도 아니다.

SHA 연결은 변조 탐지용 내부 형식이며 서명·서버 출처 증명·Windows journal 재인코딩 호환이 아니다. 외부 프로세스가 저장소 전체를 삭제하거나 일관된 과거 묶음으로 치환하는 경우를 검증할 외부 신뢰 anchor는 없다. 규칙을 따르지 않는 외부 프로세스의 모든 경로 교체 경쟁까지 방어한 것은 아니다.

시간·세션·생명주기는 기존 합성 환경이다. 이번 디스크 I/O의 실제 벽시계 소요 시간을 합성 deadline에 자동 합산하지 않는다. 실제 시계/세션/transport 연결, iOS 실행 저널의 전용 컨테이너 및 파일 보호 연결·실기기 검증은 별도 미완료다. target에서는 컴파일만 하며 UI 호출 경로는 추가하지 않는다.

baseline_ready/applied, execution_allowed, app_binding_created, editing_allowed, sending_allowed, automatic_receive_allowed는 계속 false다. 실제 관찰 raw·handshake·최신성·profile·Windows 체인 호환에 대한 기존 미검증 상태를 승격하지 않는다.
