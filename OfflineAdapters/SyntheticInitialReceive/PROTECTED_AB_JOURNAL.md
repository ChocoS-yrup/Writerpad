# 전용 컨테이너와 합성 실행 저널의 연결

2026-09-14. 오프라인 구현이며 실제 기기에서 실행한 결과가 아니다.

`ProtectedABJournalWork`는 하나의 BoundaryLease를 전용 컨테이너 준비, 저널 I/O, 완료 결과 확인에 공통으로 적용한다. 전달된 파일 보호 대역의 check가 무동작이어도 외부 lease 검사는 생략되지 않는다. 입력 경로는 고정 합성 fixture와 합성 transport뿐이다.

전용 컨테이너 `Library/Application Support/WriterPadReceiveBoundary-v1`의 기존 seal을 확인한 뒤 알려진 하위 이름 `execution-journal` 하나를 허용한다. 기존 `physical-boundary`와 파일을 공유하지 않는다. 기존 물리 저장소 검사가 저널 내용까지 검증했다는 뜻은 아니며 각 저장소는 자신의 검증기를 사용한다.

호스트 임시 경로 전용 initializer의 제한은 유지한다. 새 protected initializer는 검증된 container 객체에서 경로와 보호 접근 기능을 얻는다. owner 형식은 `synthetic-ab-protected-journal-v1`로 구분하므로 기존 호스트 owner를 보호 완료로 받아들이지 않는다. owner에는 현재의 container 경로도 결합된다.

새 저널 디렉터리·lock·owner·record·head 및 .pending 파일에 파일 보호 설정/대조를 적용한다. 새 파일은 내용 쓰기 전에 보호를 설정하며, 기존 파일이 약한 보호이면 자동 수정하지 않는다. 읽기 전후, payload 쓰기 전, pending fsync 이후 rename 전, 게시 후, 마지막 검증에 lease/protection 확인을 수행한다. 관찰된 철회 뒤에는 다음 단계로 넘어가지 않는다. OS 호출 중 발생한 알림을 순간적으로 원자 취소한다는 보장은 아니다.

작업 실패 시 기존 사용량을 환불하지 않는다. 보호 데이터 접근이 막히면 추정 stopped 기록도 쓰지 않고 현재 증거를 보존한다. 잠금 해제/foreground 복귀 뒤 새 lease로 기록을 읽을 수 있어도 running/stopped/finished 또는 다시 연 초기 저널을 재실행하지 않는다. pending·부분 초기화는 복구·삭제하지 않는다.

`ProtectedABJournalCompletion.checkedReport()`는 lease, 저널 전체의 보호·해시 연결, 완료 상태 digest, 기존 합성 완료 권한을 재확인한다. 반환된 결과도 이후 잠금·백그라운드 전환·저널 손상·보호 약화가 있으면 성공을 다시 게시할 수 없다.

`IOSBoundaryController.validateSyntheticJournal()`에 호출 가능한 연결을 추가했다. OS가 제공한 자기 home과 bundle을 사용하고 `.complete` 보호 설정 및 기존 앱 알림 lease를 연결한다. 부모 작업 취소는 detached 작업으로 전달하며 main actor에서 결과를 게시하기 전에 취소/lease를 다시 확인한다. 초기화·자동 실행·새 UI 버튼은 추가하지 않았다. 별도 syntheticJournalReady만 관리하며 기존 실제 적용/실행 권한은 false다.

호스트 검사는 inode에 보호 여부를 기록하는 메모리 대역과 새 fake home을 사용한다. 실제 iOS NSFileProtectionComplete 동작, 잠금/재부팅 후 영속성, 앱 알림·취소의 실기기 동작은 미검증이다. generic iOS 빌드는 컴파일 확인이다. 이전 호스트 프로세스 종료 검사를 이 보호 대역의 OS 보호 증거로 확대하지 않는다.

기존 A/B 시각·세션·boot·생명주기 context 값은 여전히 합성 환경의 기록이다. 이번 연결에서 실제 앱 lease는 별도의 메모리 실행 권한이며 합성 context 값을 실제 로그인/기기 세대로 승격하지 않는다. 실제 시계/세션/transport 및 디스크 I/O 벽시계 비용과 deadline 연결, Windows 체인 호환·실제 raw/handshake 의미·최신성 검증은 남아 있다. 실제 baseline, 실제 local UUID, 서명/설치, 관문/hold/prod는 변경하지 않는다.
