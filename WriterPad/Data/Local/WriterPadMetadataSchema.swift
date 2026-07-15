import Foundation
import SwiftData

/// WriterPad 메타데이터의 최초 버전이다. 서버 revision과 원고 본문은 포함하지 않는다.
enum WriterPadSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            BootstrapRecord.self,
            ProjectRecord.self,
            DocumentRecord.self,
            AppStateRecord.self,
            WorkspaceRecord.self
        ]
    }
}

/// 후속 버전이 생기면 이전 스키마를 유지하고 명시적 단계를 추가한다.
enum WriterPadMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [WriterPadSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}

@Model
final class ProjectRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var modifiedAt: Date

    init(id: UUID, name: String, createdAt: Date, modifiedAt: Date) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}

@Model
final class DocumentRecord {
    @Attribute(.unique) var id: UUID
    var projectID: UUID
    var kindRawValue: String
    var parentID: UUID?
    var relativePath: String
    var userOrder: Int
    var modifiedAt: Date
    var contentHash: String?
    var isDeleted: Bool
    var originalPath: String?
    var deletedAt: Date?
    var cursorLocation: Int
    var selectionLength: Int
    var isExpanded: Bool

    init(
        id: UUID,
        projectID: UUID,
        kindRawValue: String,
        parentID: UUID?,
        relativePath: String,
        userOrder: Int,
        modifiedAt: Date,
        contentHash: String?,
        isDeleted: Bool,
        originalPath: String?,
        deletedAt: Date?,
        cursorLocation: Int,
        selectionLength: Int,
        isExpanded: Bool
    ) {
        self.id = id
        self.projectID = projectID
        self.kindRawValue = kindRawValue
        self.parentID = parentID
        self.relativePath = relativePath
        self.userOrder = userOrder
        self.modifiedAt = modifiedAt
        self.contentHash = contentHash
        self.isDeleted = isDeleted
        self.originalPath = originalPath
        self.deletedAt = deletedAt
        self.cursorLocation = cursorLocation
        self.selectionLength = selectionLength
        self.isExpanded = isExpanded
    }
}

@Model
final class AppStateRecord {
    @Attribute(.unique) var key: String
    var lastProjectID: UUID?

    init(key: String = "writerpad.app-state", lastProjectID: UUID? = nil) {
        self.key = key
        self.lastProjectID = lastProjectID
    }
}

@Model
final class WorkspaceRecord {
    @Attribute(.unique) var projectID: UUID
    var leftDocumentID: UUID?
    var rightDocumentID: UUID?
    var isSplitEnabled: Bool
    var activePaneRawValue: String
    var binderWidth: Double

    init(
        projectID: UUID,
        leftDocumentID: UUID? = nil,
        rightDocumentID: UUID? = nil,
        isSplitEnabled: Bool = false,
        activePaneRawValue: String = EditorPane.left.rawValue,
        binderWidth: Double = SwiftDataMetadataRepository.defaultBinderWidth
    ) {
        self.projectID = projectID
        self.leftDocumentID = leftDocumentID
        self.rightDocumentID = rightDocumentID
        self.isSplitEnabled = isSplitEnabled
        self.activePaneRawValue = activePaneRawValue
        self.binderWidth = binderWidth
    }
}

enum WriterPadMetadataStore {
    static let schema = Schema(WriterPadSchemaV1.models)

    static func makeContainer(
        isStoredInMemoryOnly: Bool,
        storeURL: URL? = nil
    ) throws -> ModelContainer {
        let configuration: ModelConfiguration

        if let storeURL {
            configuration = ModelConfiguration(
                "WriterPadMetadata",
                schema: schema,
                url: storeURL
            )
        } else {
            configuration = ModelConfiguration(
                "WriterPadMetadata",
                schema: schema,
                isStoredInMemoryOnly: isStoredInMemoryOnly
            )
        }

        return try ModelContainer(
            for: schema,
            migrationPlan: WriterPadMigrationPlan.self,
            configurations: [configuration]
        )
    }
}
