# iPad 독립 프로젝트 백업·복구 core

이 문서는 기존 `LocalBackupStore`의 문서별 workspace 내부 snapshot과 별도로,
프로젝트 전체를 독립 위치에 보존하는 A1 core의 형식과 안전 경계를 기록한다.
이 단계는 제품 UI, 원격 저장소, 실제 원고 연결 또는 기존 백업 정리를 포함하지 않는다.

## 디렉터리 형식 v1

호출자가 원본 workspace 밖의 존재하지 않는 목적지 URL을 지정한다. 생성 결과는 복제하기
쉬운 단일 디렉터리이며 압축이 필요한 경우 이 디렉터리를 바이트 그대로 별도 복제한다.

```text
선택한-백업-디렉터리/
├── manifest.json
└── files/
    └── 메인/
        ├── 원고/...
        └── 메모장/...
```

`files/` 아래 TXT는 원본 상대 경로와 UTF-8 bytes를 그대로 유지한다. `manifest.json`에는
다음을 기록한다.

- format 이름과 version
- backup UUID와 생성 시각
- project UUID, 이름과 생성·수정 시각
- 모든 folder/document UUID
- parent UUID, 종류, 상대 경로와 사용자 순서
- 문서별 UTF-8 byte count와 SHA-256
- 휴지통 상태, cursor와 폴더 확장 상태를 포함한 기존 `DocumentNode` 메타데이터

## 생성 안전 규칙

1. 프로젝트 ID와 모든 node의 project ID가 같아야 한다.
2. document ID와 상대 경로는 중복될 수 없다.
3. parent ID는 같은 manifest의 folder를 가리키고 실제 상대 경로 구조와 일치해야 한다.
4. 절대 경로, `.`·`..`, 빈 component, backslash와 NUL을 거부한다.
5. 원본 경로와 패키지 내부의 symbolic link를 거부한다.
6. TXT는 UTF-8이어야 하며 기록된 metadata hash가 있으면 실제 SHA-256과 일치해야 한다.
7. 목적지는 원본 workspace 밖에 있고 아직 존재하지 않아야 한다.
8. 형제 임시 디렉터리에 완성·검증한 뒤 최종 이름으로 이동한다.
9. 실패 시 이 작업이 만든 임시 디렉터리만 정리하고 원본과 기존 목적지는 변경하지 않는다.

## 검증과 복구 시연

검증기는 manifest 형식, ID·부모·경로 관계, 파일 종류, UTF-8 byte count, SHA-256,
누락·추가 파일과 symbolic link를 다시 검사한다. 하나라도 다르면 복구를 시작하지 않는다.

복구는 존재하지 않는 빈 목적지에만 수행한다.

1. 검증된 manifest의 folder 구조를 임시 복구 디렉터리에 생성한다.
2. 각 UTF-8 TXT를 원래 상대 경로에 복사한다.
3. `writerpad-project-manifest.json`으로 UUID와 구조 메타데이터를 함께 보존한다.
4. 임시 복구 결과의 모든 파일과 manifest를 다시 검증한다.
5. 최종 목적지로 이동한 뒤 같은 검증을 한 번 더 실행한다.

이 복구 결과는 원고·폴더 구조·UUID·hash가 실제로 다시 만들어지는 증거다. 아직 앱의 운영
metadata DB로 자동 import하지 않으며, 기존 프로젝트를 자동 승격하거나 덮어쓰지 않는다.

## 보존 정책

기본 보존 기간은 30일이다. A1 core는 `createdAt < now - 30일`이고 pinned가 아닌 패키지를
정리 후보로 계산할 뿐 삭제하지 않는다. 기존 백업 삭제와 retention 실행은 별도 승인 대상이다.

## A1 검증 범위

- 합성 프로젝트의 한글·supplementary Unicode·빈 문서
- project/folder/document UUID와 parent 관계
- 원본과 복구본의 상대 경로·UTF-8 bytes·SHA-256
- 기존 목적지, workspace 내부 목적지, 손상 bytes, 추가 파일과 symbolic link 거부
- 실패 시 원본 불변과 owned partial directory 정리
- 30일 후보 계산이 실제 파일을 삭제하지 않음

실제 원고, 기존 프로젝트, 기존 backup, incident 자료와 원격 Supabase는 사용하지 않는다.
