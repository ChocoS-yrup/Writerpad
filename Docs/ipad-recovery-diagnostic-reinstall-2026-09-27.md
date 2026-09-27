# 복구 진단 앱 서명 갱신 및 덮어 설치 — 2026-09-27

## 결과

- 사용자 요청으로 `ChocoS 복구 진단`을 삭제 없이 동일 앱 ID `com.chocos.writerpad.debug`로 덮어 설치했다.
- 기존 작업 트리의 구현을 그대로 빌드했다. 이번 작업에서 Swift 코드·계약·서버·Windows 동작은 변경하지 않았다.
- Debug 실기기 빌드 성공(exit 0), 빌드 로그의 `warning:` / `error:` 0건. 샌드박스 밖 `codesign --verify --deep --strict` 성공.
- 새 embedded provisioning profile: LocalProvision=true, 발급 `2026-09-27T03:22:26Z`, 만료 `2026-10-04T03:22:26Z`(한국시간 10월 4일 12:22:26).
- 이전 설치본의 정확한 서명 만료일은 확인하지 못했다. 새 설치본은 기기 설치와 실행에 성공했고, 후속 조회에서도 WriterPad 프로세스가 실행 중이었다.

## 복구 시험 상태 보존

전체 백업이나 복원은 하지 않았다. 비교용으로 마지막 journal record와 draft 두 파일만 읽었다.

- 설치 전후 `000000000116.record`와 `draft.json`을 `cmp`로 비교하여 각각 바이트 동일 확인.
- record SHA-256: `d4a059397cca0db195d480fec30e6dea6c2f40d153edf02a1b00c81d267879d3`
- draft SHA-256: `f252ec6c3fbef4b336863c547ae633a7102d370b729ada2bccbecb0c25a39b91`
- 마지막 이벤트 `actionStopped`, lastFailure `NORMAL_RECOVERY_CHECKPOINT`, baseline revision 9.
- A 시험 run `0ef0b8a9-2bfb-4c55-a5b9-e2f6178ce794`, beforeHTTP checkpoint 유지.
- 활성 batch `4f9c1a5e-7d2b-45aa-958c-5cfdb11a7ba8`는 frozen, journal attempts 0.
- request hash `0c2d2ab761fa3f637da7bc669ff09426bcfb044bd3f0437fc97e0104be9ddd76` 유지.
- 추가 시험 환경변수 없이 실행했으며 로그인·준비·송수신·본문 편집은 실행하지 않았다. 실행 후 파일 목록도 116번이 최신이었다.
- 사용자가 재설치 후 정상 화면 표시를 확인했다. A 시험 완료나 서버 상태 확인을 의미하지 않는다.

## 빌드 및 다음 단계

빌드 설정은 `.debug` bundle suffix, `ChocoS 복구 진단` display name,
`WRITERPAD_RECEIVE_VALIDATION`, `WRITERPAD_NORMAL_EDITOR`, `WRITERPAD_NORMAL_EDITOR_RECOVERY` compilation flags를 유지했다.
`-allowProvisioningUpdates`로 프로파일을 갱신했다.

로컬 임시 증거(정리될 수 있음):

- `/private/tmp/writerpad-reinstall-20260927-build.log`
- `/private/tmp/writerpad-reinstall-20260927-ZtlXyj/`

다음은 사용자의 화면 재실행 확인 후, 기존 run/request를 유지한 A 시험 재개다. 새 시험 run을 만들거나 자동 송신하지 않는다.
프로비저닝 만료에 관한 Apple 안내: https://developer.apple.com/help/account/basics/about-your-developer-account
