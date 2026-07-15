import Foundation
import SwiftData

extension SwiftDataMetadataRepository: WorkspaceStateRepository {
    func lastProjectID() async throws -> ProjectID? {
        guard let rawID = try uniqueAppStateRecord()?.lastProjectID else {
            return nil
        }
        let id = ProjectID(rawValue: rawID)
        guard try uniqueProjectRecord(id: id) != nil else {
            throw MetadataRepositoryError.corruptedRecord(
                entity: "AppStateRecord",
                identifier: rawID.uuidString,
                reason: "last project does not exist"
            )
        }
        return id
    }

    func setLastProjectID(_ projectID: ProjectID?) async throws {
        if let projectID {
            _ = try requireProjectRecord(id: projectID)
        }
        let record: AppStateRecord
        if let existing = try uniqueAppStateRecord() {
            record = existing
        } else {
            record = AppStateRecord()
            modelContext.insert(record)
        }
        record.lastProjectID = projectID?.rawValue
        try modelContext.save()
    }

    func editorState(for projectID: ProjectID) async throws -> EditorWorkspaceState {
        _ = try requireProjectRecord(id: projectID)
        guard let record = try uniqueWorkspaceRecord(projectID: projectID) else {
            return EditorWorkspaceState(
                projectID: projectID,
                left: EditorPaneState(documentID: nil, cursor: .start),
                right: nil,
                activePane: .left
            )
        }
        guard let activePane = EditorPane(rawValue: record.activePaneRawValue) else {
            throw MetadataRepositoryError.corruptedRecord(
                entity: "WorkspaceRecord",
                identifier: projectID.rawValue.uuidString,
                reason: "unknown active pane"
            )
        }
        let left = try paneState(rawDocumentID: record.leftDocumentID, projectID: projectID)
        let right = record.isSplitEnabled
            ? try paneState(rawDocumentID: record.rightDocumentID, projectID: projectID)
            : nil
        guard activePane != .right || right != nil else {
            throw MetadataRepositoryError.invalidEditorState(projectID)
        }
        return EditorWorkspaceState(
            projectID: projectID,
            left: left,
            right: right,
            activePane: activePane
        )
    }

    func saveEditorState(_ state: EditorWorkspaceState) async throws {
        _ = try requireProjectRecord(id: state.projectID)
        guard state.activePane != .right || state.right != nil else {
            throw MetadataRepositoryError.invalidEditorState(state.projectID)
        }
        try validatePane(state.left, projectID: state.projectID)
        if let right = state.right {
            try validatePane(right, projectID: state.projectID)
        }

        let record: WorkspaceRecord
        if let existing = try uniqueWorkspaceRecord(projectID: state.projectID) {
            record = existing
        } else {
            record = WorkspaceRecord(projectID: state.projectID.rawValue)
            modelContext.insert(record)
        }
        record.leftDocumentID = state.left.documentID?.rawValue
        record.rightDocumentID = state.right?.documentID?.rawValue
        record.isSplitEnabled = state.right != nil
        record.activePaneRawValue = state.activePane.rawValue

        try saveCursorWithoutCommit(state.left.cursor, for: state.left.documentID)
        if let right = state.right {
            try saveCursorWithoutCommit(right.cursor, for: right.documentID)
        }
        try modelContext.save()
    }

    func binderWidth(for projectID: ProjectID) async throws -> Double {
        _ = try requireProjectRecord(id: projectID)
        return try uniqueWorkspaceRecord(projectID: projectID)?.binderWidth ?? Self.defaultBinderWidth
    }

    func setBinderWidth(_ width: Double, for projectID: ProjectID) async throws {
        guard width.isFinite, width > 0 else {
            throw MetadataRepositoryError.invalidBinderWidth(width)
        }
        _ = try requireProjectRecord(id: projectID)
        let record: WorkspaceRecord
        if let existing = try uniqueWorkspaceRecord(projectID: projectID) {
            record = existing
        } else {
            record = WorkspaceRecord(projectID: projectID.rawValue)
            modelContext.insert(record)
        }
        record.binderWidth = width
        try modelContext.save()
    }

    func expandedFolderIDs(in projectID: ProjectID) async throws -> Set<DocumentID> {
        _ = try requireProjectRecord(id: projectID)
        var result = Set<DocumentID>()
        for record in try documentRecords(in: projectID) where record.isExpanded {
            guard record.kindRawValue == DocumentKind.folder.rawValue else {
                throw MetadataRepositoryError.corruptedRecord(
                    entity: "DocumentRecord",
                    identifier: record.id.uuidString,
                    reason: "expanded node is not a folder"
                )
            }
            result.insert(DocumentID(rawValue: record.id))
        }
        return result
    }

    func setExpanded(_ isExpanded: Bool, for folderID: DocumentID) async throws {
        let record = try requireDocumentRecord(id: folderID)
        guard record.kindRawValue == DocumentKind.folder.rawValue else {
            throw MetadataRepositoryError.parentIsNotFolder(folderID)
        }
        record.isExpanded = isExpanded
        try modelContext.save()
    }

    func cursor(for documentID: DocumentID) async throws -> TextCursorState {
        try domainDocument(from: requireDocumentRecord(id: documentID)).cursor
    }

    func saveCursor(_ cursor: TextCursorState, for documentID: DocumentID) async throws {
        try saveCursorWithoutCommit(cursor, for: documentID)
        try modelContext.save()
    }

    private func paneState(
        rawDocumentID: UUID?,
        projectID: ProjectID
    ) throws -> EditorPaneState {
        guard let rawDocumentID else {
            return EditorPaneState(documentID: nil, cursor: .start)
        }
        let id = DocumentID(rawValue: rawDocumentID)
        let document = try domainDocument(from: requireDocumentRecord(id: id))
        guard document.projectID == projectID else {
            throw MetadataRepositoryError.corruptedRecord(
                entity: "WorkspaceRecord",
                identifier: projectID.rawValue.uuidString,
                reason: "editor document belongs to another project"
            )
        }
        return EditorPaneState(documentID: id, cursor: document.cursor)
    }

    private func validatePane(_ pane: EditorPaneState, projectID: ProjectID) throws {
        guard let documentID = pane.documentID else {
            return
        }
        let document = try requireDocumentRecord(id: documentID)
        guard document.projectID == projectID.rawValue else {
            throw MetadataRepositoryError.invalidEditorState(projectID)
        }
    }

    private func saveCursorWithoutCommit(
        _ cursor: TextCursorState,
        for documentID: DocumentID?
    ) throws {
        guard let documentID else {
            return
        }
        guard let location = Int(exactly: cursor.location),
              let length = Int(exactly: cursor.selectionLength)
        else {
            throw MetadataRepositoryError.invalidCursor(documentID)
        }
        let document = try requireDocumentRecord(id: documentID)
        document.cursorLocation = location
        document.selectionLength = length
    }
}
