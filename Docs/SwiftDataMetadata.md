# SwiftData V1 메타데이터 계층

## 스키마

`WriterPadSchemaV1`의 버전은 1.0.0이다. `WriterPadMigrationPlan`은 V1을 등록하며 현재 migration stage는 비어 있다. 후속 버전은 V1 모델을 수정해 덮어쓰지 않고 새 VersionedSchema와 명시적 stage를 추가한다.

| 레코드 | unique 기준 | 주요 정보 |
|---|---|---|
| `ProjectRecord` | `id` | 이름, 생성·수정 시각 |
| `DocumentRecord` | `id` | 작품·부모 UUID, 경로, 순서, 해시, 삭제·커서·펼침 상태 |
| `AppStateRecord` | singleton key | 마지막 작품 UUID |
| `WorkspaceRecord` | `projectID` | 좌우 문서, 분할 상태, 활성 편집기, 바인더 너비 |

`BootstrapRecord`는 초기 Xcode 기반에서 만들어진 기존 빈 저장소와의 연속성을 위한 구동 표식이다. 원고나 사용자 기능 데이터는 담지 않는다.

휴지통 여부의 Swift 필드는 SwiftData 자체 삭제 상태와 충돌하지 않는 `isTrashed`다. 기존 V1 저장 필드명 `isDeleted`는 `@Attribute(originalName:)`으로 유지해 호환성을 보존한다.

## 저장소 격리

`SwiftDataMetadataRepository`는 `@ModelActor`로 격리하며 다음 protocol을 한 저장 문맥에서 구현한다.

- `ProjectRepository`
- `DocumentRepository`
- `WorkspaceStateRepository`

View는 ModelContext에 직접 접근하지 않는다. `AppEnvironment`가 동일 actor를 세 경계에 주입한다.

## 무결성 규칙

- 저장하려는 문서의 작품이 존재해야 한다.
- 부모 ID가 있으면 같은 작품의 기존 폴더여야 한다.
- 문서가 자기 자신을 부모로 가리킬 수 없다.
- 기존 document ID의 project ID는 변경할 수 없다.
- 같은 document ID 저장은 중복 행 생성이 아니라 기존 행 갱신이다.
- 알 수 없는 문서 종류, 잘못된 SHA-256, 음수 커서, 불완전 휴지통 정보는 손상 오류다.
- 활성 오른쪽 편집기는 오른쪽 편집기 상태가 있을 때만 허용한다.

## 조회 전략

UUID와 singleton key는 SwiftData unique 제약으로 중복을 막는다. Xcode 26.6의 strict concurrency 모드에서 predicate key path가 향후 Swift 6 오류 경고를 생성하므로 V1 저장소는 actor 내부 fetch 후 식별자를 필터링한다. 7단계의 1,000화 성능 기준선에서 비용을 측정하고 경고 없는 인덱스 조회 API가 안정화되면 교체한다.

## 실패와 복구

저장소는 SwiftData 오류나 `MetadataRepositoryError`를 숨기지 않는다. 오류 처리 경로는 TXT 저장 protocol을 호출하지 않으므로 원고를 수정하지 않는다.

복구 원칙:

1. 손상 메타데이터 오류와 식별자를 사용자에게 보고한다.
2. 기존 SwiftData 파일과 TXT를 임의로 삭제하지 않는다.
3. 2-4 가져오기·재조정 계층에서 TXT 폴더를 읽기 전용 스캔한다.
4. 새 인메모리 또는 복구 저장소에서 결과를 검증한다.
5. 검증 성공 후에만 메타데이터 저장소 교체를 제안한다.

서버 큐와 revision은 Windows v2 확정 후 별도 스키마 버전에서 추가한다.
