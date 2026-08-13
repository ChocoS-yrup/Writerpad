# storage-name-v2 iPad 실기기 이름 스캔 — 2026-08-13

## 판정

`storage-name-v2` 개정 동결 전에 확인하기로 한 실제 iPad 이름 스캔은
`PASS`다. WriterPad의 `Documents` 컨테이너에서 파일 내용은 읽지 않고 이름
메타데이터만 재귀 열거했으며, 개정안이 새로 거부하거나 별도 방어해야 하는 이름은
0건이었다.

이 결과는 계약 개정 전 데이터 이관 위험을 확인하는 증거다. 계약 문안 변경,
클라이언트 배선, 서버 변경, 프로젝트 승격 또는 이름변경 incident 수정은 수행하지
않았다.

## 기준선

```yaml
stage_id: ipad-storage-name-v2-device-scan-20260813
repository: https://github.com/ChocoS-yrup/Writerpad
base_main_sha: 20d60ea94da4cd2543db489ea240efa5db2f4091
contract_version: 0.2.0
contract_git_commit: fcd99b7098b9a04bd93c585d89b16588aa482530
canonical_contract_sha256: 416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670
windows_repository: https://github.com/ChocoS-yrup/WriterPad_main
windows_handoff_commit: 9313cde92376c3be121fe589f7b52179098bdbfd
windows_handoff_document: docs/ipad-contract-client-handoff.md
device_model: iPad Pro 11-inch (M4) (iPad16,3)
device_identifier_sha256: c78ecf85723171f504c9ff167288a584e4ce2148fb65d23fcc47a09b9b9810f0
app_bundle_id: com.chocos.writerpad
app_version: 0.1.0
app_build: 1
captured_at: 2026-08-13T13:15:24+0900
```

기기 식별자 원문과 사용자 파일명은 공개 증거에 넣지 않았다. 기기 식별자는 같은
실기기에서 다시 측정했는지 로컬에서 대조할 수 있도록 SHA-256만 기록했다.

## 측정 방법

연결된 기기와 설치 앱을 읽기 전용으로 확인한 뒤 다음 형태의 명령으로 앱 데이터
컨테이너의 `Documents` 메타데이터를 열거했다.

```text
xcrun devicectl list devices
xcrun devicectl device info apps \
  --device <redacted-device-id> \
  --bundle-id com.chocos.writerpad
xcrun devicectl device info files \
  --device <redacted-device-id> \
  --domain-type appDataContainer \
  --domain-identifier com.chocos.writerpad \
  --subdirectory Documents \
  --recurse \
  --json-output <private-temporary-path> \
  --quiet
```

열거 결과의 각 `name`을 Unicode scalar 단위로 검사했다. 이번 선행 조건이 지정한
범위는 다음과 같다.

- BMP Private Use Area: `U+E000..U+F8FF`
- Tags: `U+E0000..U+E007F`
- Variation Selectors Supplement: `U+E0100..U+E01EF`
- Supplementary Private Use Area-A/B
- 모든 상위면 scalar (`> U+FFFF`)
- 상위면 scalar 바로 뒤의 canonical combining class 비영(非零) scalar 또는
  `U+FF9E`/`U+FF9F`

추가로 인수인계에 보존된 Unicode 14.0.0 동결 할당 범위
(`canonical_sha256 = aed4e530cc5e0de638310db961f17f174d605282764a6657afd0f70e5515c85c`)
밖 scalar와 제외 범위
(`canonical_sha256 = f56ee73bca1690e842a189336ffdfabe7625128f7f314a7ac567755952571e86`)
도 검사했다.

## 결과

```yaml
container_entry_count: 1010
directory_count: 161
file_count: 849
symlink_count: 0
filename_scalar_occurrence_count: 56230
unicode_14_baseline_outside_occurrence_count: 0
unicode_14_baseline_outside_path_count: 0
excluded_scalar_occurrence_count: 0
excluded_scalar_path_count: 0
supplementary_scalar_occurrence_count: 0
supplementary_scalar_path_count: 0
risky_supplementary_pair_count: 0
result: PASS
```

상위면 scalar 자체가 0건이므로 위험 인접 배열 판정은 호스트 Unicode 판의 combining
class 차이에 의존하지 않는다.

## 비공개 원본 증거

재귀 열거 JSON에는 사용자 파일명이 포함되므로 저장소에 커밋하거나 push하지 않았다.

```yaml
raw_listing_bytes: 850046
raw_listing_sha256: 153eeac32918681f9ca3027d1b0175ca0aa87476c12e00d3341e10b64788da57
sorted_relative_path_digest_algorithm: >-
  relativePath UTF-8 bytes를 bytewise 오름차순으로 정렬하고,
  각 항목 앞에 4-byte big-endian 길이를 붙여 이어 쓴 뒤 SHA-256
sorted_relative_path_sha256: c3adca5e8291215a65a434c42393a82885b3396aefb3700ead76c4a344059ba8
public_raw_names: omitted-sensitive-user-data
```

원본은 측정 Mac의 `/private/tmp/writerpad-ipad-file-list-20260813.json`에만 두었다.
이 경로는 임시 영역이므로 장기 보존 근거로 주장하지 않는다. 공개 가능한 판정 근거는
이 문서의 비식별 집계와 digest다.

## 제한과 다음 경계

- 이 스캔은 2026-08-13 13:15:24 KST의 한 시점 스냅샷이다. 이후 새 이름에는 새
  계약 검사를 적용해야 한다.
- 실제 파일 내용, 운영 서버, incident 프로젝트와 서버 데이터는 읽거나 바꾸지 않았다.
- 기존 프로젝트를 자동 또는 수동 승격하지 않았다.
- 마지막 세 이름변경 사건의 직접 원인은 이 스캔으로 확인되지 않았으며 수정하지 않았다.
- 이 PASS는 계약 개정 동결의 데이터 선행 조건만 닫는다. 계약 개정, 서버 allowlist,
  iPad/Windows pin 교체 또는 공유 종단간 검증 완료를 뜻하지 않는다.
