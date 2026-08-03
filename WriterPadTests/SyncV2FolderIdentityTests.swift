import Foundation
import XCTest
@testable import WriterPad

final class SyncV2FolderIdentityTests: XCTestCase {
    private let serverProjectID = UUID(
        uuidString: "00000000-0000-0000-0000-0000000000f0"
    )!

    /// 두 기기가 각자 이관해도 같은 값이 나와야 한다. 무작위였다면 같은 폴더가
    /// 서버에 둘로 등록된다.
    func testDerivedIdentityIsStableAcrossDevices() {
        let first = SyncV2FolderIdentity.derived(
            serverProjectID: serverProjectID,
            relativePath: "메인/메모장/가 나 다"
        )
        let second = SyncV2FolderIdentity.derived(
            serverProjectID: serverProjectID,
            relativePath: "메인/메모장/가 나 다"
        )

        XCTAssertEqual(first, second)
    }

    /// 경로가 다르면 값도 달라야 하고, 작품이 다르면 같은 경로여도 달라야 한다.
    func testDerivedIdentitySeparatesPathsAndProjects() {
        let base = SyncV2FolderIdentity.derived(
            serverProjectID: serverProjectID,
            relativePath: "메인/메모장/가"
        )
        let otherPath = SyncV2FolderIdentity.derived(
            serverProjectID: serverProjectID,
            relativePath: "메인/메모장/나"
        )
        let otherProject = SyncV2FolderIdentity.derived(
            serverProjectID: UUID(),
            relativePath: "메인/메모장/가"
        )

        XCTAssertNotEqual(base, otherPath)
        XCTAssertNotEqual(base, otherProject)
    }

    /// macOS 파일 이름은 한글 자모가 분해된 형태로 들어올 수 있다. 정규화하지
    /// 않으면 Windows가 보낸 같은 폴더가 다른 값을 받는다.
    func testDerivedIdentityNormalizesDecomposedHangul() {
        let composed = "메인/메모장/가나다"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        // Swift의 문자열 비교는 정규화 차이를 무시하므로 바이트로 확인한다.
        // UUID 계산은 바이트를 그대로 쓰기 때문에 이 차이가 결과를 가른다.
        XCTAssertFalse(
            composed.utf8.elementsEqual(decomposed.utf8),
            "fixture가 실제로 분해된 형태여야 이 테스트가 의미를 갖는다."
        )

        XCTAssertEqual(
            SyncV2FolderIdentity.derived(
                serverProjectID: serverProjectID,
                relativePath: composed
            ),
            SyncV2FolderIdentity.derived(
                serverProjectID: serverProjectID,
                relativePath: decomposed
            )
        )
    }

    /// 이관은 폴더 식별자만 바꾸고 문서 식별자는 건드리지 않는다. 문서는 이미
    /// 서버에서 자기 UUID로 식별되므로 바꾸면 동기화가 깨진다.
    func testMigrationKeepsDocumentIdentifiersAndRewiresParents() {
        let projectID = ProjectID(rawValue: UUID())
        let notes = folder(
            projectID: projectID,
            path: "메인/메모장",
            parent: nil
        )
        let inner = folder(
            projectID: projectID,
            path: "메인/메모장/자료",
            parent: notes.id
        )
        let document = text(
            projectID: projectID,
            path: "메인/메모장/자료/메모.txt",
            parent: inner.id
        )

        let plan = SyncV2FolderIdentity.migrationPlan(
            documents: [notes, inner, document],
            serverProjectID: serverProjectID
        )

        let migratedNotes = plan.upserts.first {
            $0.relativePath == notes.relativePath
        }
        let migratedInner = plan.upserts.first {
            $0.relativePath == inner.relativePath
        }
        let migratedDocument = plan.upserts.first {
            $0.relativePath == document.relativePath
        }
        XCTAssertEqual(
            migratedNotes?.id,
            SyncV2FolderIdentity.derived(
                serverProjectID: serverProjectID,
                relativePath: "메인/메모장"
            )
        )
        XCTAssertEqual(
            migratedDocument?.id,
            document.id,
            "문서 식별자는 그대로여야 한다."
        )
        XCTAssertEqual(
            migratedDocument?.parentID,
            migratedInner?.id,
            "자식은 새 부모 식별자를 가리켜야 한다."
        )
        XCTAssertEqual(
            Set(plan.removedFolderIDs),
            Set([notes.id, inner.id])
        )
    }

    /// 부모가 먼저 저장되어야 자식의 parentID가 가리킬 대상이 있다.
    func testMigrationOrdersParentsBeforeChildren() {
        let projectID = ProjectID(rawValue: UUID())
        let outer = folder(projectID: projectID, path: "메인/메모장", parent: nil)
        let middle = folder(
            projectID: projectID,
            path: "메인/메모장/가",
            parent: outer.id
        )
        let inner = folder(
            projectID: projectID,
            path: "메인/메모장/가/나",
            parent: middle.id
        )

        let plan = SyncV2FolderIdentity.migrationPlan(
            documents: [inner, outer, middle],
            serverProjectID: serverProjectID
        )

        let depths = plan.upserts.map {
            $0.relativePath.rawValue.split(separator: "/").count
        }
        XCTAssertEqual(depths, depths.sorted())
    }

    /// 두 번 돌려도 결과가 같아야 한다. 이미 이관된 폴더는 계산값과 같으므로
    /// 바꿀 것이 없다.
    func testMigrationIsIdempotentForAlreadyDerivedFolders() {
        let projectID = ProjectID(rawValue: UUID())
        let migrated = DocumentNode(
            id: SyncV2FolderIdentity.derived(
                serverProjectID: serverProjectID,
                relativePath: "메인/메모장"
            ),
            projectID: projectID,
            kind: .folder,
            parentID: nil,
            relativePath: RelativeDocumentPath(rawValue: "메인/메모장"),
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )

        let plan = SyncV2FolderIdentity.migrationPlan(
            documents: [migrated],
            serverProjectID: serverProjectID
        )

        XCTAssertTrue(plan.isEmpty)
    }

    /// 두 폴더가 같은 값으로 계산되면 경로가 겹친다는 뜻이다. 그대로 이관하면
    /// 한쪽이 사라지므로 아무것도 바꾸지 않는다.
    func testMigrationStopsWhenTwoFoldersDeriveTheSameIdentity() {
        let projectID = ProjectID(rawValue: UUID())
        let first = folder(
            projectID: projectID,
            path: "메인/메모장/가나다",
            parent: nil
        )
        let second = folder(
            projectID: projectID,
            path: "메인/메모장/가나다"
                .decomposedStringWithCanonicalMapping,
            parent: nil
        )

        let plan = SyncV2FolderIdentity.migrationPlan(
            documents: [first, second],
            serverProjectID: serverProjectID
        )

        XCTAssertTrue(plan.isEmpty)
    }

    private func folder(
        projectID: ProjectID,
        path: String,
        parent: DocumentID?
    ) -> DocumentNode {
        DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .folder,
            parentID: parent,
            relativePath: RelativeDocumentPath(rawValue: path),
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
    }

    private func text(
        projectID: ProjectID,
        path: String,
        parent: DocumentID?
    ) -> DocumentNode {
        DocumentNode(
            id: DocumentID(rawValue: UUID()),
            projectID: projectID,
            kind: .text,
            parentID: parent,
            relativePath: RelativeDocumentPath(rawValue: path),
            userOrder: 0,
            modifiedAt: .distantPast,
            contentHash: nil
        )
    }
}
