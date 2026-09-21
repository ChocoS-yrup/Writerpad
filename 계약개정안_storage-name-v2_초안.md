# 계약 개정안 초안 — storage-name-v2

작성 2026-08-13 / iPad 세션. **아직 `protocol.json`에 반영하지 않았습니다.**
양쪽 합의 후 반영하고, 서버 allowlist 등록까지 끝난 뒤에 클라이언트 핀을 올립니다.

근거 측정은 `윈도우세션_회신*.md`와 `유니코드측정_*.json`에 있습니다.

---

## 1. 무엇을 고치는가

현재 계약은 `storage_name_unicode: 15.0.0`으로 **런타임이 특정 Unicode 판을 쓸 것**을
요구합니다. 이 요구는 지킬 수 없다는 것이 실측으로 드러났습니다.

```
iPad     Foundation의 folding(.caseInsensitive)이 default case folding이 아니다.
         전 코드포인트에서 276개가 갈렸고 그중 181개가 베이스라인 안쪽이었다.
         "미할당만 막으면 된다"로는 걸러지지 않는 자리다.
Windows  요구를 만족시키려고 unicodedata2 pyd를 exe에 번들했다.
         그 pip 핀 하나가 모든 쓰기의 단일 장애점이 됐다.
서버     이미 옳게 하고 있었다. 표를 동결해 넣고 런타임에서 읽는다.
```

**서버가 하던 방식을 계약의 방식으로 올립니다.** 런타임 판 요구를 버리고 동결 표로
바꿉니다.

추가로, 개정 없이는 닫히지 않는 결함 세 가지를 같이 막습니다.

```
분리자 7개    NFKC가 만들어 내는 '/' 와 '\' 가 검사를 빠져나간다 (양쪽 공통)
PUA 등        사설 영역이 충돌 키 재료로 들어가 있다
상위면 절단   Foundation NFKC가 코드포인트를 16비트로 자른다 (iPad 한정)
```

---

## 2. `protocol.json` 변경 제안

### 2-1. `storage_name_normalization`

`algorithm_id`를 `storage-name-v2`로 올립니다. 받아들여지던 이름 중 일부가 거부로
바뀌므로 같은 id를 쓸 수 없습니다.

```json
"storage_name_normalization": {
  "algorithm_id": "storage-name-v2",
  "baseline_unicode_version": "14.0.0",
  "tables": {
    "assigned_baseline": "unicode/assigned-baseline-14.0.0.json",
    "excluded_scalars":  "unicode/excluded-scalars.json",
    "casefold":          "unicode/casefold-15.0.0.json"
  },
  "input_scope": "one folder or file name segment, never a path",
  "steps": [
    "Reject any scalar not covered by assigned-baseline-14.0.0.json (STORAGE_NAME_UNASSIGNED).",
    "Reject any scalar covered by excluded-scalars.json (STORAGE_NAME_UNSUPPORTED_SCALAR).",
    "Reject a supplementary-plane scalar immediately followed by a scalar with combining class other than zero, or by U+FF9E or U+FF9F (STORAGE_NAME_INVALID).",
    "Apply Unicode Normalization Form KC.",
    "Apply full default case folding per scalar using casefold-15.0.0.json, without locale.",
    "Apply Unicode Normalization Form KC again.",
    "Reject U+0000 through U+001F, U+007F, slash, and backslash (STORAGE_NAME_INVALID).",
    "Remove every trailing U+0020 SPACE or U+002E FULL STOP.",
    "Reject an empty result, dot, or dot-dot (STORAGE_NAME_INVALID).",
    "Take the substring before the first U+002E FULL STOP and reject Windows device basenames CON, PRN, AUX, NUL, COM1 through COM9, and LPT1 through LPT9 (STORAGE_NAME_RESERVED).",
    "Encode the remaining string as UTF-8; these exact bytes are the sibling collision key."
  ],
  "separator_policy": "Separators are rejected, not rewritten. The check runs after normalization so that scalars which normalize into a separator are also rejected.",
  "runtime_unicode_policy": "No implementation may consult its runtime's Unicode data for this algorithm. Normalization form KC is the only step left to the platform, and step 3 bounds the damage a non-conforming implementation can do.",
  "leading_space_policy": "Leading U+0020 is preserved.",
  "internal_space_policy": "Internal Unicode whitespace is preserved subject to NFKC_Casefold.",
  "comparison_policy": "Compare collision-key UTF-8 bytes for exact equality.",
  "conformance_vectors": "conformance_vectors/storage-name-v1.json"
}
```

삭제: `unicode_version: "15.0.0"`.

### 2-2. 단계 순서가 이번 개정의 핵심입니다

두 검사가 **서로 반대 방향**입니다. 하나로 묶으면 반드시 한쪽이 깨집니다.

```
3번  상위면 인접 검사     NFKC '이전'이어야 한다
     NFKC가 상위면 스칼라를 없애 버린다. U+10041 U+0301 -> U+00C1.
     뒤에서 보면 검사할 대상이 남아 있지 않다.

7번  분리자·제어문자 검사  NFKC '이후'여야 한다
     NFKC가 분리자를 만들어 낸다. U+FF0F -> '/', U+2105 -> 'c/o'.
     앞에서 보면 7개를 놓친다.
```

1·2번을 입력에만 걸어도 되는 근거: 정규화 안정성 정책에 따라 베이스라인 안쪽 문자의
NFKC 결과는 다시 베이스라인 안쪽입니다. 다만 3번이 필요한 이유가 정확히 "런타임 NFKC가
그 보장을 어긴다"는 것이므로, 방어적으로 7번 뒤에 베이스라인 재검사를 한 번 더 두는
것을 권합니다. 비용이 작습니다.

### 2-3. 오류 코드 3종

`standard_error_codes`에 둘을 추가합니다.

```
STORAGE_NAME_UNASSIGNED           베이스라인 표에 없는 스칼라
STORAGE_NAME_UNSUPPORTED_SCALAR   할당돼 있지만 이름에 쓰지 않기로 정한 스칼라
```

가르는 기준은 사용자에게 하는 설명이 달라지느냐입니다. 앞은 "그 문자는 이 계약이 아는
문자가 아니다", 뒤는 "그 문자는 알지만 이름에는 못 쓴다"입니다.

분리자 7개와 3번 배열 위반은 `STORAGE_NAME_INVALID`로 흡수합니다. 앞은 고칠 방법이
자명하고, 뒤는 스칼라가 아니라 배열에 대한 제약이라 스칼라 단위 코드를 주기 어렵습니다.

### 2-4. 능력 선언

```json
"storage_name_v2": {
  "since_protocol": 3,
  "scope": "structure",
  "meaning": "Storage-name collision keys use frozen Unicode tables and the storage-name-v2 rejection rules. No runtime Unicode data is consulted."
}
```

`storage_name_v1`은 남겨 두되 개정 후 클라이언트는 선언하지 않습니다. 서버는 둘 다
받아들일 수 있어야 이관 중 한쪽만 올라간 상태를 넘길 수 있습니다.

### 2-5. `contract-lock.json`

```json
"unicode_assets": {
  "unicode/casefold-15.0.0.json":          "eac289d0d721c58867acb07af38d9a8e8ee374d328b33d93251ae6348e258439",
  "unicode/assigned-baseline-14.0.0.json": "aed4e530cc5e0de638310db961f17f174d605282764a6657afd0f70e5515c85c",
  "unicode/excluded-scalars.json":         "f56ee73bca1690e842a189336ffdfabe7625128f7f314a7ac567755952571e86",
  "unicode/assigned-15.0.0.json":          "5a354149c4f2b58f7c2ffc5eab9fc92f6eab5a68292ebce626f4ba402f736e31"
}
```

각 값은 파일 바이트가 아니라 **정규형**의 SHA-256입니다. JSON 들여쓰기나 키 순서가
달라져도 흔들리지 않아야 세 구현이 같은 값을 낼 수 있습니다. 정규형 정의는 각 파일과
`sync-contract/unicode/README.md`에 있습니다.

---

## 3. 적합성 벡터 추가

기존 SN-001..015는 **한 개도 바뀌지 않습니다**(실측 확인). 아래를 더합니다.

| id | 입력 | 기대 |
|---|---|---|
| SN-016 | `a／b` (U+0061 U+FF0F U+0062) | `STORAGE_NAME_INVALID` |
| SN-017 | `℅` (U+2105) | `STORAGE_NAME_INVALID` |
| SN-018 | U+FE68 | `STORAGE_NAME_INVALID` |
| SN-019 | `a` U+E000 `b` | `STORAGE_NAME_UNSUPPORTED_SCALAR` |
| SN-020 | U+E0041 (태그) | `STORAGE_NAME_UNSUPPORTED_SCALAR` |
| SN-021 | U+E0100 (VS 보충) | `STORAGE_NAME_UNSUPPORTED_SCALAR` |
| SN-022 | U+1CCD6 | `STORAGE_NAME_UNASSIGNED` |
| SN-023 | U+10D50 | `STORAGE_NAME_UNASSIGNED` |
| SN-024 | U+13046 U+0301 | `STORAGE_NAME_INVALID` (3번 (a)) |
| SN-025 | U+13046 U+FF9E | `STORAGE_NAME_INVALID` (3번 (b)) |
| SN-026 | U+13046 U+0061 | 통과, `f093818661` |
| SN-027 | U+1F642 U+FE0F | 통과, `f09f9982efb88f` |
| SN-028 | U+AB70 | 통과, `e18ea0` |
| SN-029 | U+1C80 | 통과, `d0b2` |

SN-026·SN-027이 특히 중요합니다.

- **SN-026** — 3번 규칙을 "상위면 전체 금지"로 과잉 구현하는 것을 막습니다.
  상위면 문자 뒤에 결합문자가 아닌 것이 오면 통과해야 합니다.
- **SN-027** — U+FE0F를 제외 목록에 쓸어 넣는 것을 막습니다. IME가 자동 삽입하는
  문자이고, 이모지 영역은 측정에서 발산 0건이었습니다. 막으면 정상 이모지 폴더명이
  거부됩니다.

SN-028·SN-029는 동결 표가 실제로 쓰이는지 봅니다. Foundation 접기로 되돌아가면 이 둘이
먼저 깨집니다(각각 U+AB70, U+1C80이 그대로 남음).

기대 키는 전부 동결 표 기준 구현으로 계산해 확인했습니다.

---

## 4. 서버 변경

**빠뜨리면 서버가 클라이언트보다 느슨해집니다.**

`private.nfkc_unicode15`는 미할당 문자를 만나면 거부하지 않고 버퍼를 끊어 **그 문자를
그대로 통과**시킨 뒤 이어서 정규화합니다. 개정 후 클라이언트는 그런 이름을 거부하므로,
서버만 받아 주는 이름이 생깁니다.

```
[ ] private.storage_name_v1 -> storage_name_v2 로 규칙 교체
      베이스라인 게이트 / 제외 스칼라 / 3번 배열 검사 / 분리자 검사 위치 이동
[ ] private.unicode_baseline_assigned_ranges 테이블 신설 (698 범위)
      assigned-baseline-14.0.0.json 에서 생성
[ ] allowlist 에 새 digest 등록
```

기존 `unicode15_assigned_ranges`와 `unicode15_casefold`는 그대로 둡니다. 이미 적용된
마이그레이션은 바뀌지 않습니다.

---

## 5. 클라이언트 변경

```
iPad     [x] 접기를 동결 표로 (완료, 커밋 1a5938a)
         [ ] 1~3번 검사 추가
         [ ] 7번 검사를 NFKC 뒤로 이동
         [ ] 능력 선언 storage_name_v2
         [ ] 핀 4개 갱신

Windows  [진행] 접기를 동결 표로 (동작 무변화 확인됨)
         [ ] 1~3번 검사 추가
         [ ] 7번 검사 이동
         [ ] 능력 선언, 핀 4개 갱신
         [ ] unicodedata2 제거 (spec hiddenimports, requirements)
```

---

## 6. 기존 데이터 영향

**재키잉이 필요 없습니다.** 이번 개정은 받아들이던 이름 일부를 거부로 바꿀 뿐,
받아들이는 이름의 키는 하나도 바꾸지 않습니다.

```
Windows 실사용 이름 15,952개   PUA·태그·VS·상위면  0건
iPad 도달 범위 1,424개         전부 0건
```

**선행 조건 하나** — iPad 실기기 저장소 스캔이 남아 있습니다. 위 두 스캔은 실기기
데이터를 포함하지 않습니다. 0건이 확인된 뒤에 개정을 동결하는 것이 안전합니다.

---

## 7. 배포 순서

순서를 어기면 `CONTRACT_DIGEST_MISMATCH`로 전면 차단됩니다.

```
1  iPad 실기기 이름 스캔 (0건 확인)
2  개정 문안 동결 — protocol.json, contract-lock.json, 벡터, 스키마
3  서버 수정 + 새 digest allowlist 등록 + 배포
4  클라이언트 핀 교체 (Windows / iPad 각각)
5  그 다음에야 iPad 동기화 배선
```

3번 전에 4번을 하면 클라이언트가 막히고, 4번 전에 5번을 하면 잘못된 키가 올라갑니다.

---

## 8. 열린 것

1. **방어적 재검사** — 2-2의 "7번 뒤 베이스라인 재검사"를 넣을지. 저희는 넣는 쪽입니다.
2. **`storage_name_v1` 능력 유지 기간** — 서버가 둘 다 받는 기간을 언제 끝낼지.
3. **`verify_contract.py`의 Unicode 의존** — 이 검증기 자체가 호스트 CPython의
   `unicodedata`가 15.0.0일 것을 요구해서, 그 판이 없는 기계에서는 실행되지 않습니다.
   클라이언트에서 없앤 것과 똑같은 취약점이 검증기에 남아 있습니다. 동결 표를 읽도록
   같이 뒤집는 것을 제안합니다.
