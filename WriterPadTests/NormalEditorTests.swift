import Foundation
import SQLite3
import SwiftUI
import UIKit
import XCTest
@testable import WriterPad

@MainActor
final class NormalEditorCredentialFieldTests: XCTestCase {
    private func withCredentialForm(_ check: (UIWindow, NormalEditorCredentialFocus, NormalEditorCredentialTextField,
                                             NormalEditorCredentialTextField, UITextView) throws -> Void) rethrows {
        let focus = NormalEditorCredentialFocus()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let host = UIViewController()
        window.rootViewController = host
        let email = NormalEditorCredentialTextField(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        let password = NormalEditorCredentialTextField(frame: CGRect(x: 0, y: 50, width: 300, height: 44))
        let manuscript = UITextView(frame: CGRect(x: 0, y: 100, width: 600, height: 400))
        manuscript.text = "unchanged manuscript"
        for field in [email, password] { field.credentialFocus = focus; host.view.addSubview(field) }
        focus.register(email, secure: false); focus.register(password, secure: true)
        password.isSecureTextEntry = true
        host.view.addSubview(manuscript)
        window.makeKeyAndVisible()
        defer { window.endEditing(true); window.isHidden = true }
        try check(window, focus, email, password, manuscript)
    }

    func testTabAndShiftTabStayInCredentialFieldsAndDoNotEditManuscript() throws {
        try withCredentialForm { _, _, email, password, manuscript in
            XCTAssertTrue(email.becomeFirstResponder())
            let tab = try XCTUnwrap(email.keyCommands?.first { $0.input == "\t" && $0.modifierFlags.isEmpty })
            XCTAssertTrue(tab.wantsPriorityOverSystemBehavior)
            email.moveCredentialFocus(tab)
            XCTAssertTrue(password.isFirstResponder)
            password.insertText("synthetic-only")
            XCTAssertEqual(password.text, "synthetic-only")
            let back = try XCTUnwrap(password.keyCommands?.first { $0.input == "\t" && $0.modifierFlags == .shift })
            XCTAssertTrue(back.wantsPriorityOverSystemBehavior)
            password.moveCredentialFocus(back)
            XCTAssertTrue(email.isFirstResponder)
            email.moveCredentialFocus(back)
            XCTAssertTrue(password.isFirstResponder)
            password.moveCredentialFocus(tab)
            XCTAssertTrue(email.isFirstResponder)
            XCTAssertFalse(manuscript.isFirstResponder)
            XCTAssertEqual(manuscript.text, "unchanged manuscript")
        }
    }

    func testTabDoesNotSubmitOrMutateBindings() throws {
        var value = "synthetic-only"
        var submissions = 0
        try withCredentialForm { _, focus, email, password, manuscript in
            let subject = NormalEditorCredentialField(text: Binding(get: { value }, set: { value = $0 }),
                isSecure: true, focus: focus, onSubmit: { submissions += 1 })
            let coordinator = subject.makeCoordinator()
            subject.updateTextField(password, coordinator: coordinator)
            XCTAssertTrue(password.becomeFirstResponder())
            let tab = try XCTUnwrap(password.keyCommands?.first { $0.input == "\t" && $0.modifierFlags.isEmpty })
            password.moveCredentialFocus(tab)
            XCTAssertTrue(email.isFirstResponder)
            XCTAssertEqual(value, "synthetic-only")
            XCTAssertEqual(submissions, 0)
            XCTAssertEqual(manuscript.text, "unchanged manuscript")
        }
    }

    func testMissingOrDisabledPeerDoesNotReleaseEmailFocus() {
        withCredentialForm { _, focus, email, password, _ in
            XCTAssertTrue(email.becomeFirstResponder())
            password.isEnabled = false
            focus.move(from: email)
            XCTAssertTrue(email.isFirstResponder)
            focus.unregister(password)
            focus.move(from: email)
            XCTAssertTrue(email.isFirstResponder)
        }
    }

    func testInactiveFieldCannotStealFocusFromManuscript() {
        withCredentialForm { _, _, email, _, manuscript in
            XCTAssertTrue(manuscript.becomeFirstResponder())
            email.moveCredentialFocus(UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(NormalEditorCredentialTextField.moveCredentialFocus)))
            XCTAssertTrue(manuscript.isFirstResponder)
        }
    }

    func testEmailReturnMovesToPasswordWithoutSubmitting() {
        withCredentialForm { _, focus, email, password, _ in
            let subject = NormalEditorCredentialField(text: .constant("test@example.invalid"), isSecure: false, focus: focus)
            let coordinator = subject.makeCoordinator()
            XCTAssertTrue(email.becomeFirstResponder())
            XCTAssertFalse(coordinator.textFieldShouldReturn(email))
            XCTAssertTrue(password.isFirstResponder)
            let field = subject.makeTextField(coordinator: coordinator)
            XCTAssertEqual(field.returnKeyType, .next)
        }
    }

    func testDismantledOldFieldDoesNotUnregisterReplacement() {
        withCredentialForm { _, focus, email, password, _ in
            let subject = NormalEditorCredentialField(text: .constant(""), isSecure: false, focus: focus)
            let coordinator = subject.makeCoordinator()
            let old = subject.makeTextField(coordinator: coordinator)
            focus.register(email, secure: false)
            NormalEditorCredentialField.dismantleUIView(old, coordinator: coordinator)
            XCTAssertNil((old as? NormalEditorCredentialTextField)?.credentialFocus)
            XCTAssertTrue(password.becomeFirstResponder())
            focus.move(from: password)
            XCTAssertTrue(email.isFirstResponder)
        }
    }

    func testEmailUsesStableUIKitTraitsWithoutAssistantShortcuts() {
        let subject = NormalEditorCredentialField(text: .constant("test@example.invalid"), isSecure: false)
        let coordinator = subject.makeCoordinator()
        let field = subject.makeTextField(coordinator: coordinator)
        XCTAssertFalse(field.isSecureTextEntry)
        XCTAssertEqual(field.textContentType, .username)
        XCTAssertEqual(field.keyboardType, .emailAddress)
        XCTAssertEqual(field.autocapitalizationType, .none)
        XCTAssertEqual(field.autocorrectionType, .no)
        XCTAssertTrue(field.inputAssistantItem.leadingBarButtonGroups.isEmpty)
        XCTAssertTrue(field.inputAssistantItem.trailingBarButtonGroups.isEmpty)
        XCTAssertNil(field.inputAccessoryView)
        XCTAssertEqual(field.text, "test@example.invalid")
    }

    func testPasswordRemainsSecureAcrossUpdatesAndClearsFromModel() {
        var value = "synthetic-password"
        let subject = NormalEditorCredentialField(text: Binding(get: { value }, set: { value = $0 }), isSecure: true)
        let coordinator = subject.makeCoordinator()
        let field = subject.makeTextField(coordinator: coordinator)
        XCTAssertTrue(field.isSecureTextEntry)
        XCTAssertEqual(field.textContentType, .password)
        XCTAssertTrue(field.inputAssistantItem.leadingBarButtonGroups.isEmpty)
        XCTAssertTrue(field.inputAssistantItem.trailingBarButtonGroups.isEmpty)
        subject.updateTextField(field, coordinator: coordinator)
        XCTAssertEqual(field.text, value)
        value = ""
        subject.updateTextField(field, coordinator: coordinator)
        XCTAssertEqual(field.text, "")
        XCTAssertTrue(field.isSecureTextEntry)
    }

    func testEditingChangedDeliversLatestTextWithoutSubmitting() {
        var value = ""
        var submits = 0
        let subject = NormalEditorCredentialField(text: Binding(get: { value }, set: { value = $0 }),
            isSecure: true, onSubmit: { submits += 1 })
        let coordinator = subject.makeCoordinator()
        let field = subject.makeTextField(coordinator: coordinator)
        field.text = "synthetic-input"
        field.sendActions(for: .editingChanged)
        XCTAssertEqual(value, "synthetic-input")
        XCTAssertEqual(submits, 0)
    }

    func testReturnPublishesLatestPasswordBeforeSingleSubmission() {
        var value = ""
        var submitted: [String] = []
        let subject = NormalEditorCredentialField(text: Binding(get: { value }, set: { value = $0 }),
            isSecure: true, onSubmit: { submitted.append(value) })
        let coordinator = subject.makeCoordinator()
        let field = subject.makeTextField(coordinator: coordinator)
        field.text = "latest-synthetic-input"
        XCTAssertFalse(coordinator.textFieldShouldReturn(field))
        XCTAssertEqual(submitted, ["latest-synthetic-input"])
        XCTAssertEqual(field.returnKeyType, .go)
    }

    func testUpdateRefreshesCoordinatorBindingWithoutResettingSelection() {
        var first = "unchanged"
        var second = "unchanged"
        let original = NormalEditorCredentialField(text: Binding(get: { first }, set: { first = $0 }), isSecure: false)
        let coordinator = original.makeCoordinator()
        let field = original.makeTextField(coordinator: coordinator)
        let cursor = field.position(from: field.beginningOfDocument, offset: 3)!
        field.selectedTextRange = field.textRange(from: cursor, to: cursor)
        let updated = NormalEditorCredentialField(text: Binding(get: { second }, set: { second = $0 }), isSecure: false)
        updated.updateTextField(field, coordinator: coordinator)
        XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: field.selectedTextRange!.start), 3)
        field.text = "new"
        field.sendActions(for: .editingChanged)
        XCTAssertEqual(first, "unchanged")
        XCTAssertEqual(second, "new")
    }

    func testDismantleRemovesCallbacksAndCredentialText() {
        var value = "synthetic"
        let subject = NormalEditorCredentialField(text: Binding(get: { value }, set: { value = $0 }), isSecure: true)
        let coordinator = subject.makeCoordinator()
        let field = subject.makeTextField(coordinator: coordinator)
        NormalEditorCredentialField.dismantleUIView(field, coordinator: coordinator)
        XCTAssertNil(field.delegate)
        XCTAssertTrue(field.text?.isEmpty != false)
        field.text = "late"
        field.sendActions(for: .editingChanged)
        XCTAssertEqual(value, "synthetic")
    }
}

private let normalInitial = "일반 본문 검증 20260912\n이 문서는 일반 동기화 시험용 합성 원고입니다.\n끝.\niPad 일반 검증 20260912\nWindows 일반 검증 20260912\nWindows 일반 편집 검증 20260913\niPad 일반 편집 검증 20260913\nWindows 자동저장 검증 20260913\n"
private func normalSnapshot(_ text: String = normalInitial, revision: Int64 = 6) -> SyncV2RemoteDocumentSnapshot {
    .init(documentID: NormalEditorPlan.document, relativePath: NormalEditorPlan.path, content: text, revision: revision,
          isDeleted: false, deletedAt: nil, updatedAt: Date(timeIntervalSince1970: 100), parentFolderID: NormalEditorPlan.parent,
          name: GeneralValidationPlan.name, structureRevision: 1)
}
private func normalBatch(_ text: String, batch: UUID = UUID(), operation: UUID = UUID()) -> LocalMutationBatch {
    .init(batchID: batch, projectID: NormalEditorPlan.local, localTransactionID: nil,
          mutations: [.documentSnapshot(operationID: operation, documentID: .init(rawValue: NormalEditorPlan.document),
              relativePath: .init(rawValue: NormalEditorPlan.path), content: text,
              contentHash: ContentHash(rawValue: NormalEditorPlan.hash(text))!, localSaveGeneration: 1, isDeleted: false)])
}
private actor NormalTestRepository: DocumentRepository {
    var node = DocumentNode(id: .init(rawValue: NormalEditorPlan.document), projectID: NormalEditorPlan.local, kind: .text,
        parentID: .init(rawValue: NormalEditorPlan.parent), relativePath: .init(rawValue: NormalEditorPlan.path), userOrder: 0,
        modifiedAt: Date(timeIntervalSince1970: 100), contentHash: .init(rawValue: NormalEditorPlan.initialHash))
    var folders: [DocumentNode] = []
    func addFolders(root: UUID) {
        folders = [DocumentNode(id: .init(rawValue: root), projectID: NormalEditorPlan.local, kind: .folder,
            parentID: nil, relativePath: .init(rawValue: "메인"), userOrder: 0, modifiedAt: Date(), contentHash: nil),
            DocumentNode(id: .init(rawValue: NormalEditorPlan.parent), projectID: NormalEditorPlan.local, kind: .folder,
            parentID: .init(rawValue: root), relativePath: .init(rawValue: "메인/원고"), userOrder: 0, modifiedAt: Date(), contentHash: nil)]
    }
    func documents(in projectID: ProjectID) -> [DocumentNode] { projectID == node.projectID ? folders + [node] : [] }
    func document(id: DocumentID) -> DocumentNode? { id == node.id ? node : folders.first { $0.id == id } }
    func save(_ document: DocumentNode) { if document.id == node.id { node = document } else { folders.removeAll { $0.id == document.id }; folders.append(document) } }
    func removeMetadata(id: DocumentID) {}
}
private actor NormalTestBackend: NormalEditorBackend {
    var base = normalSnapshot()
    var server = normalSnapshot()
    let file: URL
    var prepared = false
    var failBeforeHTTP = false
    var loseResponse = false
    var failCompletion = false
    var failApplyAfterText = false
    var missingReceipt = false
    var requests: [SyncV2ContractRequest] = []
    var reads = 0
    var receiptReads = 0
    var finishes = 0
    var prepares = 0
    var structureRefreshes = 0
    var testRetirements = 0
    var duplicateReconciliations = 0
    var beforeBaseline: (@Sendable () async -> Void)?
    let device = UUID()
    init(file: URL) { self.file = file }
    func configure(before: Bool = false, lost: Bool = false, completion: Bool = false, apply: Bool = false, missing: Bool = false) {
        failBeforeHTTP = before; loseResponse = lost; failCompletion = completion; failApplyAfterText = apply; missingReceipt = missing
    }
    func setRemote(_ text: String, revision: Int64) { server = normalSnapshot(text, revision: revision) }
    func onNextBaseline(_ action: @escaping @Sendable () async -> Void) { beforeBaseline = action }
    func localBaseline() async -> SyncV2RemoteDocumentSnapshot {
        let action = beforeBaseline; beforeBaseline = nil
        await action?()
        return base
    }
    func localText() throws -> String { try String(contentsOf: file, encoding: .utf8) }
    func prepare() { prepares += 1; prepared = true }
    func refreshStructureReference() throws {
        guard prepared else { throw NormalEditorError.locked }
        structureRefreshes += 1
    }
    func retireUnsentTestQueue() throws {
        guard prepared else { throw NormalEditorError.locked }
        testRetirements += 1
    }
    func reconcileDuplicateSaves() { duplicateReconciliations += 1 }
    func invalidate() { prepared = false }
    func remote() throws -> SyncV2RemoteDocumentSnapshot {
        guard prepared else { throw NormalEditorError.locked }; reads += 1; return server
    }
    func freeze(_ source: LocalMutationBatch) throws -> SyncV2ContractRequest {
        guard prepared, case let .documentSnapshot(operation, _, _, text, _, _, _) = source.mutations[0] else { throw NormalEditorError.locked }
        return try SyncV2Contract.buildDocumentCommitRequest(projectID: NormalEditorPlan.server, projectSyncMode: .idBased,
            migrationEpoch: 1, writerDeviceID: device, documentID: NormalEditorPlan.document, intentKind: .update,
            baseRevision: Int(base.revision), parentFolderID: NormalEditorPlan.parent, name: GeneralValidationPlan.name,
            content: text, isDeleted: false, structureRevision: 1, operationID: operation, batchID: source.batchID)
    }
    func transmit(_ request: SyncV2ContractRequest, willStart: @escaping @Sendable () throws -> Void) throws -> SyncV2JSON {
        guard prepared else { throw NormalEditorError.locked }
        if failBeforeHTTP { throw NormalEditorError.locked }
        try willStart(); requests.append(request)
        let payload = request.orderedIntents[0].objectValue!["payload"]!.objectValue!
        server = normalSnapshot(payload["content"]!.stringValue!, revision: base.revision + 1)
        if loseResponse { throw URLError(.networkConnectionLost) }
        return makeGeneralCommitResponseForTesting(.init(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server, request: request))
    }
    func receipt(_ request: SyncV2ContractRequest) throws -> SyncV2JSON? {
        guard prepared else { throw NormalEditorError.locked }; receiptReads += 1
        if missingReceipt { return nil }
        return makeGeneralCommitResponseForTesting(.init(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server, request: request))
    }
    func complete(_ request: SyncV2ContractRequest, response: SyncV2JSON) throws {
        guard prepared else { throw NormalEditorError.locked }
        if failCompletion { throw NormalEditorError.storage }
        base = server; finishes += 1
    }
    func apply(_ receive: NormalEditorJournal.Receive, willApply: @escaping @Sendable () throws -> Void) throws {
        guard prepared else { throw NormalEditorError.locked }
        try willApply()
        try Data(receive.remote.content.utf8).write(to: file, options: .atomic)
        if failApplyAfterText { throw NormalEditorError.partial }
        base = receive.remote
    }
}

private func normalStructure(expanded: Bool = false, targetRevision: Int = 6) -> SyncV2PreparationSnapshot {
    let root = "e87a0e44-9a8d-4b18-b974-b40f4ab1eaad"
    let parent = NormalEditorPlan.parent.uuidString.lowercased(), memo = NormalEditorStructureReference.memo.uuidString.lowercased()
    let added = "58ed531f-56a3-4279-b0da-d5dbe5209839", existingDoc = "955ff845-aa32-4f10-956e-bac83501b205"
    let addedDoc = "0eb1aece-7212-4e8d-a5a1-fa0dbeaa89db", target = NormalEditorPlan.document.uuidString.lowercased()
    let project = SyncV2JSON.string(NormalEditorPlan.server.uuidString.lowercased())
    func folder(_ id: String, _ parent: String?, _ name: String) -> SyncV2JSON {
        .object(["folder_id": .string(id), "project_id": project, "parent_folder_id": parent.map(SyncV2JSON.string) ?? .null,
                 "name": .string(name), "revision": .int(1), "is_deleted": .bool(false)])
    }
    func doc(_ id: String, _ parent: String, _ name: String, _ path: String, _ revision: Int) -> SyncV2JSON {
        .object(["document_id": .string(id), "project_id": project, "parent_folder_id": .string(parent), "name": .string(name),
                 "relative_path": .string(path), "revision": .int(revision), "structure_revision": .int(1), "is_deleted": .bool(false)])
    }
    func order(_ parent: String?, _ children: [String], _ revision: Int = 1) -> SyncV2JSON {
        let id = syncV2UUIDv5(namespace: NormalEditorPlan.server, name: "test-order:" + (parent ?? "root"))
        return .object(["tree_order_id": .string(id.uuidString.lowercased()), "project_id": project,
                        "parent_folder_id": parent.map(SyncV2JSON.string) ?? .null,
                        "children": .array(children.map(SyncV2JSON.string)), "revision": .int(revision)])
    }
    return .init(folders: [folder(root, nil, "메인"), folder(parent, root, "원고"), folder(memo, root, "메모장")]
        + (expanded ? [folder(added, memo, "다른시험")] : []),
        documents: [doc(target, parent, GeneralValidationPlan.name, NormalEditorPlan.path, targetRevision),
                    doc(existingDoc, memo, "왕복.txt", "메인/메모장/왕복.txt", expanded ? 3 : 2)]
        + (expanded ? [doc(addedDoc, added, "빈문서.txt", "메인/메모장/다른시험/빈문서.txt", 1)] : []),
        treeOrders: [order(nil, [root]), order(root, [parent, memo]), order(parent, [target], 2),
                     order(memo, [existingDoc] + (expanded ? [added] : []), expanded ? 2 : 1)]
        + (expanded ? [order(added, [addedDoc])] : []))
}

final class NormalEditorStructureReferenceTests: XCTestCase {
    private func changed(_ snapshot: SyncV2PreparationSnapshot, kind: String, index: Int, key: String, value: SyncV2JSON) -> SyncV2PreparationSnapshot {
        var folders = snapshot.folders, docs = snapshot.documents, orders = snapshot.treeOrders
        func edit(_ rows: inout [SyncV2JSON]) { var f = rows[index].objectValue!; f[key] = value; rows[index] = .object(f) }
        if kind == "folder" { edit(&folders) } else if kind == "doc" { edit(&docs) } else { edit(&orders) }
        return .init(folders: folders, documents: docs, treeOrders: orders)
    }
    func testAllowsMemoAdditionsAndOtherBodyRevisionWithoutReplacingLocalBaseline() throws {
        let local = normalStructure(), remote = normalStructure(expanded: true)
        let reference = try NormalEditorStructureReference(local: local, remote: remote)
        XCTAssertEqual(try reference.comparison(local: local), remote)
        XCTAssertEqual(local.documents.count, 2)
        XCTAssertEqual(reference.snapshot.documents.count, 3)
        XCTAssertEqual(try reference.comparison(local: normalStructure(targetRevision: 7)), remote)
    }
    func testReferenceSurvivesCodableRoundTripAndRowReordering() throws {
        let local = normalStructure(), remote = normalStructure(expanded: true)
        let reference = try NormalEditorStructureReference(local: local, remote: remote)
        let decoded = try JSONDecoder().decode(NormalEditorStructureReference.self, from: JSONEncoder().encode(reference))
        let reordered = SyncV2PreparationSnapshot(folders: local.folders.reversed(), documents: local.documents.reversed(), treeOrders: local.treeOrders.reversed())
        XCTAssertEqual(try decoded.comparison(local: reordered), remote)
    }
    func testRejectsLocalMetadataChangeAfterReferenceWasCaptured() throws {
        let reference = try NormalEditorStructureReference(local: normalStructure(), remote: normalStructure(expanded: true))
        let changed = changed(normalStructure(), kind: "doc", index: 1, key: "revision", value: .int(3))
        XCTAssertThrowsError(try reference.comparison(local: changed))
    }
    func testRejectsProtectedDocumentOrAncestorChanges() throws {
        let remote = normalStructure(expanded: true)
        for candidate in [
            changed(remote, kind: "doc", index: 0, key: "structure_revision", value: .int(2)),
            changed(remote, kind: "doc", index: 0, key: "is_deleted", value: .bool(true)),
            changed(remote, kind: "folder", index: 1, key: "revision", value: .int(2)),
            changed(remote, kind: "folder", index: 0, key: "name", value: .string("다른루트")),
            changed(remote, kind: "order", index: 2, key: "revision", value: .int(3))
        ] { XCTAssertThrowsError(try NormalEditorStructureReference(local: normalStructure(), remote: candidate)) }
    }
    func testRejectsForeignProjectDuplicateIDsAndCyclicFolders() throws {
        let remote = normalStructure(expanded: true)
        for candidate in [
            changed(remote, kind: "doc", index: 2, key: "project_id", value: .string(UUID().uuidString.lowercased())),
            changed(remote, kind: "doc", index: 2, key: "document_id", value: .string(NormalEditorPlan.document.uuidString.lowercased())),
            changed(remote, kind: "folder", index: 3, key: "parent_folder_id", value: remote.folders[3].objectValue!["folder_id"]!)
        ] { XCTAssertThrowsError(try NormalEditorStructureReference(local: normalStructure(), remote: candidate)) }
    }
    func testRejectsRegressingRevisionsAndPathsNotMatchingParents() throws {
        let remote = normalStructure(expanded: true)
        for candidate in [
            changed(remote, kind: "doc", index: 1, key: "revision", value: .int(1)),
            changed(remote, kind: "doc", index: 2, key: "relative_path", value: .string("메인/원고/탈출.txt")),
            changed(remote, kind: "order", index: 3, key: "children", value: .array([]))
        ] { XCTAssertThrowsError(try NormalEditorStructureReference(local: normalStructure(), remote: candidate)) }
    }
    func testRejectsValidGraphWithAdditionsOutsideMemo() throws {
        let root = normalStructure().folders[0].objectValue!["folder_id"]!
        var remote = changed(normalStructure(expanded: true), kind: "folder", index: 3, key: "parent_folder_id", value: root)
        remote = changed(remote, kind: "doc", index: 2, key: "relative_path", value: .string("메인/다른시험/빈문서.txt"))
        let added = remote.folders[3].objectValue!["folder_id"]!
        remote = changed(remote, kind: "order", index: 1, key: "children", value: .array(remote.treeOrders[1].objectValue!["children"]!.arrayValue! + [added]))
        remote = changed(remote, kind: "order", index: 3, key: "children", value: normalStructure().treeOrders[3].objectValue!["children"]!)
        _ = try SyncV2GeneralTree(remote).nodes(projectID: NormalEditorPlan.local)
        XCTAssertThrowsError(try NormalEditorStructureReference(local: normalStructure(), remote: remote))
    }
    func testRejectsRemovalOfPreviouslyAcknowledgedAdditions() throws {
        XCTAssertThrowsError(try NormalEditorStructureReference.validate(local: normalStructure(expanded: true), remote: normalStructure()))
    }
    func testRejectsChangedOrderWithoutNewRevision() throws {
        let remote = changed(normalStructure(expanded: true), kind: "order", index: 3, key: "revision", value: .int(1))
        XCTAssertThrowsError(try NormalEditorStructureReference(local: normalStructure(), remote: remote))
    }
}

@MainActor
final class NormalEditorTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let journal: NormalEditorJournal
        let model: NormalEditorSession
        let backend: NormalTestBackend
        let local: NormalEditorDocumentStore
        let file: URL
    }
    private func fixture(autosave: Duration = .seconds(3600)) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NormalEditorTests-" + UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace")
        let file = workspace.appendingPathComponent(NormalEditorPlan.path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(normalInitial.utf8).write(to: file)
        let journal = try NormalEditorJournal(root: root.appendingPathComponent("journal")), repository = NormalTestRepository()
        let product = LocalDocumentStore(workspaceLocator: FixedWorkspaceLocator(root: workspace), metadataUpdater: RecordingMetadataUpdater(), durableChangeRecorder: NormalEditorRecorder(journal: journal))
        let local = NormalEditorDocumentStore(local: product, journal: journal)
        let editor = EditorSessionModel(documentRepository: repository, documentStore: local,
            workspaceStateRepository: NormalTestWorkspace(), preserveDraft: { _, text, cursor in try journal.saveDraft(text: text, cursor: cursor) }, autosaveDelay: autosave)
        let backend = NormalTestBackend(file: file)
        let model = NormalEditorSession(editor: editor, journal: journal, backend: backend, documents: repository)
        await model.open()
        XCTAssertTrue(model.opened, model.message)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return .init(root: root, journal: journal, model: model, backend: backend, local: local, file: file)
    }
    func testDuplicateReconciliationIsAvailableBeforePreparationButRequiresCleanForeground() async throws {
        let f = try await fixture(), text = "복원한 본문"
        f.model.editor.updateText(text); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text, point: .beforeHTTP)) { await f.model.prepare() }
        try f.journal.update("freezeStarted") { $0.saves[0].phase = .freezing }
        try f.journal.record(normalBatch(text))
        await f.model.prepare(); XCTAssertFalse(f.model.prepared)
        XCTAssertTrue(f.model.message.contains("NORMAL_QUEUE_FAILED"))
        await f.model.reconcileDuplicateSaves()
        var count = await f.backend.duplicateReconciliations; XCTAssertEqual(count, 1)
        XCTAssertFalse(f.model.prepared); XCTAssertTrue(f.model.message.contains("동일 본문 중복 대기 정리 완료"))
        let requests = await f.backend.requests; XCTAssertTrue(requests.isEmpty)
        f.model.editor.updateText("다른 초안")
        await f.model.reconcileDuplicateSaves()
        count = await f.backend.duplicateReconciliations; XCTAssertEqual(count, 1)
        await f.model.setForeground(false); await f.model.reconcileDuplicateSaves()
        count = await f.backend.duplicateReconciliations; XCTAssertEqual(count, 1)
    }
    func testDuplicateResolutionRejectsChangedTextRequestsAndOtherRunStates() async throws {
        let f = try await fixture(), text = "복원 é"
        f.model.editor.updateText(text); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text, point: .beforeHTTP)) { await f.model.prepare() }
        try f.journal.update("freezeStarted") { $0.saves[0].phase = .freezing }
        try f.journal.record(normalBatch(text))
        let state = f.journal.state(); XCTAssertNotNil(NormalEditorDuplicateSaveResolution(state))
        for content in ["다른 본문", "복원 e\u{301}", text + "\n"] {
            var s = state; s.saves[1] = .init(source: normalBatch(content))
            XCTAssertNil(NormalEditorDuplicateSaveResolution(s))
        }
        for index in [0, 1] {
            var s = state; s.saves[index].attempts = [UUID()]; XCTAssertNil(NormalEditorDuplicateSaveResolution(s))
            s = state; s.saves[index].request = .object([:]); XCTAssertNil(NormalEditorDuplicateSaveResolution(s))
            s = state; s.saves[index].response = .object([:]); XCTAssertNil(NormalEditorDuplicateSaveResolution(s))
        }
        var s = state; s.saves[0].phase = .frozen; XCTAssertNil(NormalEditorDuplicateSaveResolution(s))
        s = state; s.recoveryRuns![0].cancelled = true; XCTAssertNil(NormalEditorDuplicateSaveResolution(s))
        s = state; s.recoveryCheckpoints = [NormalEditorRecoveryInjection.checkpointKey(s.recoveryRuns![0].configuration)]
        XCTAssertNil(NormalEditorDuplicateSaveResolution(s))
        s = state; s.error = "failed"; XCTAssertNil(NormalEditorDuplicateSaveResolution(s))
        s = state; s.baseline = normalSnapshot(revision: 7); XCTAssertNil(NormalEditorDuplicateSaveResolution(s))
    }
    func testTestQueueRetirementRequiresExplicitPreparedCleanForegroundAction() async throws {
        let f = try await fixture(), text = "취소 뒤 유지할 A 본문"
        f.model.editor.updateText(text); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text, point: .beforeHTTP)) { await f.model.prepare() }
        try f.journal.update("freezeStarted") { $0.saves[0].phase = .freezing }
        let before = try stableJSON(f.journal.state())
        await f.model.retireUnsentTestQueue()
        XCTAssertFalse(f.model.prepared)
        XCTAssertTrue(f.model.message.contains("이전 테스트 송신 대기 2건 취소 완료"))
        XCTAssertEqual(try stableJSON(f.journal.state()), before)
        XCTAssertEqual(try String(contentsOf: f.file, encoding: .utf8), text)
        await f.model.retireUnsentTestQueue(); await f.model.send()
        var count = await f.backend.testRetirements; XCTAssertEqual(count, 1)
        let requests = await f.backend.requests; XCTAssertTrue(requests.isEmpty)
        await f.model.prepare()
        f.model.editor.updateText("저장 전 변경")
        await f.model.retireUnsentTestQueue()
        count = await f.backend.testRetirements; XCTAssertEqual(count, 1)
        await f.model.setForeground(false); await f.model.retireUnsentTestQueue()
        count = await f.backend.testRetirements; XCTAssertEqual(count, 1)
    }
    func testTestQueueRetirementGateRejectsFrozenAttemptedCancelledAndConsumedStates() async throws {
        let f = try await fixture(), text = "취소 조건"
        f.model.editor.updateText(text); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text, point: .beforeHTTP)) { await f.model.prepare() }
        let original = f.journal.state(); XCTAssertTrue(NormalEditorTestQueueRetirement.canRetire(original))
        for phase: NormalEditorJournal.Phase in [.frozen, .httpStarted, .responseStored, .completed] {
            var s = original; s.saves[0].phase = phase; XCTAssertFalse(NormalEditorTestQueueRetirement.canRetire(s))
        }
        var s = original; s.saves[0].attempts = [UUID()]; XCTAssertFalse(NormalEditorTestQueueRetirement.canRetire(s))
        s = original; s.saves[0].request = .object([:]); XCTAssertFalse(NormalEditorTestQueueRetirement.canRetire(s))
        s = original; s.recoveryRuns![0].cancelled = true; XCTAssertFalse(NormalEditorTestQueueRetirement.canRetire(s))
        s = original; s.recoveryCheckpoints = [NormalEditorRecoveryInjection.checkpointKey(s.recoveryRuns![0].configuration)]
        XCTAssertFalse(NormalEditorTestQueueRetirement.canRetire(s))
    }
    func testStructureRefreshPreservesSavedSourceAndRunAndRequiresNewPreparation() async throws {
        let f = try await fixture(), text = "구조 갱신 대기 본문"
        f.model.editor.updateText(text); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text)) { await f.model.prepare() }
        let before = try stableJSON(f.journal.state()), draft = try f.journal.draft()?.hash
        await f.model.refreshStructureReference()
        XCTAssertEqual(try stableJSON(f.journal.state()), before)
        XCTAssertEqual(try f.journal.draft()?.hash, draft)
        XCTAssertEqual(try String(contentsOf: f.file, encoding: .utf8), text)
        XCTAssertFalse(f.model.prepared)
        XCTAssertTrue(f.model.message.contains("구조 비교 기준 갱신 완료"))
        await f.model.send()
        let refreshes = await f.backend.structureRefreshes, requests = await f.backend.requests
        XCTAssertEqual(refreshes, 1); XCTAssertTrue(requests.isEmpty)
    }
    func testStructureRefreshRejectsDirtyOrBackgroundSessionBeforeBackend() async throws {
        let f = try await fixture(), text = "저장본"
        f.model.editor.updateText(text); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text)) { await f.model.prepare() }
        f.model.editor.updateText("저장 전 초안")
        await f.model.refreshStructureReference()
        let firstCount = await f.backend.structureRefreshes
        XCTAssertEqual(firstCount, 0)
        await f.model.setForeground(false)
        await f.model.refreshStructureReference()
        let secondCount = await f.backend.structureRefreshes
        XCTAssertEqual(secondCount, 0)
    }
    func testStructureRefreshGateRejectsFrozenUncertainAndConsumedRuns() async throws {
        let f = try await fixture(), text = "갱신 조건"
        f.model.editor.updateText(text); await f.model.save()
        XCTAssertFalse(NormalEditorStructureReference.canRefresh(f.journal.state()))
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text)) { await f.model.prepare() }
        let clean = f.journal.state()
        XCTAssertTrue(NormalEditorStructureReference.canRefresh(clean))
        for phase: NormalEditorJournal.Phase in [.freezing, .frozen, .httpStarted, .responseStored, .completed, .superseded] {
            var state = clean; state.saves[0].phase = phase
            XCTAssertFalse(NormalEditorStructureReference.canRefresh(state))
        }
        var state = clean; state.saves[0].request = .object([:])
        XCTAssertFalse(NormalEditorStructureReference.canRefresh(state))
        state = clean; state.saves[0].attempts = [UUID()]
        XCTAssertFalse(NormalEditorStructureReference.canRefresh(state))
        state = clean; state.recoveryCheckpoints = [NormalEditorRecoveryInjection.checkpointKey(state.recoveryRuns![0].configuration)]
        XCTAssertFalse(NormalEditorStructureReference.canRefresh(state))
        state = clean; state.recoveryRuns?[0].cancelled = true
        XCTAssertFalse(NormalEditorStructureReference.canRefresh(state))
        state = clean; state.error = "blocked"
        XCTAssertFalse(NormalEditorStructureReference.canRefresh(state))
    }
    func testStructureReferenceJournalReopenDoesNotRewriteSourceDraftOrBaseline() async throws {
        let f = try await fixture(), text = "보존 본문"
        f.model.editor.updateText(text); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text)) { await f.model.prepare() }
        let before = f.journal.state(), draft = try Data(contentsOf: f.journal.root.appendingPathComponent("draft.json"))
        let reference = try NormalEditorStructureReference(local: normalStructure(), remote: normalStructure(expanded: true))
        try f.journal.update("structureComparisonReferenceRefreshed") { $0.structureReference = reference }
        let reopened = try NormalEditorJournal(root: f.journal.root)
        XCTAssertEqual(try reopened.state().structureReference?.comparison(local: normalStructure()), normalStructure(expanded: true))
        XCTAssertEqual(try stableJSON(reopened.state().saves), try stableJSON(before.saves))
        XCTAssertEqual(try stableJSON(reopened.state().recoveryRuns), try stableJSON(before.recoveryRuns))
        XCTAssertEqual(try stableJSON(reopened.state().baseline), try stableJSON(before.baseline))
        XCTAssertEqual(try Data(contentsOf: f.journal.root.appendingPathComponent("draft.json")), draft)
    }
    func testLocalSaveDoesNotRequireLoginAndPreservesUTF8AndFinalLF() async throws {
        let f = try await fixture()
        for text in ["  자유 본문\n끝  ", "NFD: e\u{301} 한글🙂\n", "NFC: é\n\n", ""] {
            f.model.editor.updateText(text); await f.model.save()
            XCTAssertEqual(try Data(contentsOf: f.file), Data(text.utf8))
            XCTAssertEqual(try f.journal.draft()?.hash, NormalEditorPlan.hash(text))
        }
        let writes = await f.backend.requests; XCTAssertTrue(writes.isEmpty)
        XCTAssertFalse(f.model.prepared)
    }
    func testCanonicallyEquivalentTextChangeIsNotDiscarded() async throws {
        let f = try await fixture()
        f.model.editor.updateText("é"); await f.model.save()
        f.model.editor.updateText("e\u{301}"); await f.model.save()
        XCTAssertEqual(try Data(contentsOf: f.file), Data("e\u{301}".utf8))
    }
    func testIdleSaveUsesProductionPathWithoutAuthentication() async throws {
        let f = try await fixture(autosave: .milliseconds(20))
        f.model.editor.updateText("유휴 저장\n")
        for _ in 0..<100 where f.journal.state().head == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(try Data(contentsOf: f.file), Data("유휴 저장\n".utf8))
        XCTAssertNotNil(f.journal.state().head)
        let requests = await f.backend.requests; XCTAssertTrue(requests.isEmpty)
    }
    func testDraftAndQueueIDsSurviveReopen() async throws {
        let f = try await fixture()
        f.model.editor.updateText("저장한 본문"); await f.model.save()
        let source = try XCTUnwrap(f.journal.state().saves.last?.source)
        f.model.editor.updateText("저장 전 초안\n")
        let reopened = try NormalEditorJournal(root: f.journal.root)
        XCTAssertEqual(reopened.state().saves.last?.source, source)
        XCTAssertEqual(try reopened.draft()?.text, "저장 전 초안\n")
    }
    func testHTTPNotStartedKeepsSameRequestForFirstTransmission() async throws {
        let f = try await fixture()
        f.model.editor.updateText("송신할 자유 원고"); await f.model.save(); await f.model.prepare()
        await f.backend.configure(before: true); await f.model.send()
        let frozen = try XCTUnwrap(f.journal.state().saves.first?.requestHash)
        XCTAssertEqual(f.journal.state().saves.first?.phase, .frozen)
        XCTAssertEqual(f.journal.state().saves.first?.attempts.count, 0)
        await f.backend.configure(); await f.model.prepare(); await f.model.send()
        XCTAssertEqual(f.journal.state().saves.first?.requestHash, frozen)
        XCTAssertEqual(f.journal.state().saves.first?.phase, .completed, f.model.message)
        let requests = await f.backend.requests; XCTAssertEqual(requests.count, 1)
    }
    func testLostResponseRequiresReceiptAndNeverResends() async throws {
        let f = try await fixture()
        f.model.editor.updateText("응답 유실 원고"); await f.model.save(); await f.model.prepare()
        await f.backend.configure(lost: true); await f.model.send()
        XCTAssertEqual(f.journal.state().saves.first?.phase, .httpStarted)
        let hash = f.journal.state().saves.first?.requestHash
        await f.model.prepare(); await f.model.send()
        XCTAssertEqual(f.journal.state().saves.first?.phase, .httpStarted)
        await f.model.prepare(); await f.model.recoverResult()
        XCTAssertEqual(f.journal.state().saves.first?.phase, .completed, f.model.message)
        XCTAssertEqual(f.journal.state().saves.first?.requestHash, hash)
        let writes = await f.backend.requests, reads = await f.backend.receiptReads
        XCTAssertEqual(writes.count, 1); XCTAssertEqual(reads, 1)
    }
    func testMissingReceiptIsNotPermissionToResend() async throws {
        let f = try await fixture()
        f.model.editor.updateText("원고"); await f.model.save(); await f.model.prepare()
        await f.backend.configure(lost: true, missing: true); await f.model.send()
        await f.model.prepare(); await f.model.recoverResult()
        XCTAssertEqual(f.journal.state().saves.first?.phase, .httpStarted)
        let writes = await f.backend.requests; XCTAssertEqual(writes.count, 1)
    }
    func testStoredResponseFinishesLocallyWithoutAnotherGETOrPOST() async throws {
        let f = try await fixture()
        f.model.editor.updateText("완료 반영 전 중단"); await f.model.save(); await f.model.prepare()
        await f.backend.configure(completion: true); await f.model.send()
        XCTAssertEqual(f.journal.state().saves.first?.phase, .responseStored)
        await f.backend.configure(); await f.model.prepare(); await f.model.recoverResult()
        let reads = await f.backend.receiptReads, writes = await f.backend.requests
        XCTAssertEqual(reads, 0); XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(f.journal.state().saves.first?.phase, .completed, f.model.message)
    }
    func testFollowingEditDoesNotReplaceFrozenOperationOrItsBody() async throws {
        let f = try await fixture()
        f.model.editor.updateText("첫 원고"); await f.model.save(); await f.model.prepare()
        await f.backend.configure(lost: true); await f.model.send()
        let first = f.journal.state().saves[0]
        f.model.editor.updateText("후속 원고"); await f.model.save()
        XCTAssertEqual(f.journal.state().saves.count, 2)
        XCTAssertEqual(f.journal.state().saves[0].requestHash, first.requestHash)
        await f.model.prepare(); await f.model.recoverResult()
        XCTAssertEqual(try Data(contentsOf: f.file), Data("후속 원고".utf8))
        XCTAssertEqual(f.journal.state().head, 1)
    }
    func testDirtyOrPendingLocalWorkBlocksReceiveBeforeGET() async throws {
        let f = try await fixture()
        f.model.editor.updateText("미저장"); await f.model.prepare(); await f.model.receive()
        var reads = await f.backend.reads; XCTAssertEqual(reads, 0)
        await f.model.save(); await f.model.prepare(); await f.model.receive()
        reads = await f.backend.reads; XCTAssertEqual(reads, 0)
        XCTAssertEqual(try Data(contentsOf: f.file), Data("미저장".utf8))
    }
    func testRemoteConflictPreservesAllThreeBodiesAcrossNewSave() async throws {
        let f = try await fixture()
        f.model.editor.updateText("로컬 변경"); await f.model.save()
        await f.backend.setRemote("상대 변경", revision: 7)
        await f.model.prepare(); await f.model.send()
        let conflict = try XCTUnwrap(f.journal.state().conflicts.first)
        XCTAssertEqual(conflict.baseline, normalInitial); XCTAssertEqual(conflict.local, "로컬 변경"); XCTAssertEqual(conflict.remote.content, "상대 변경")
        f.model.editor.updateText("후속 편집"); await f.model.save()
        XCTAssertEqual(f.journal.state().conflicts.count, 1)
        XCTAssertEqual(f.journal.state().head, 0)
        XCTAssertEqual(f.journal.state().saves[0].phase, .queued)
        let writes = await f.backend.requests; XCTAssertTrue(writes.isEmpty)
    }
    func testPartialReceiveResumesApplyWithoutRepeatingRemoteFetch() async throws {
        let f = try await fixture()
        await f.backend.setRemote("받은 원고\n", revision: 7)
        await f.backend.configure(apply: true); await f.model.prepare(); await f.model.receive()
        XCTAssertEqual(f.journal.state().receive?.phase, "originalApplyStarted")
        XCTAssertEqual(try Data(contentsOf: f.file), Data("받은 원고\n".utf8))
        await f.backend.configure(); await f.model.prepare(); await f.model.receive()
        XCTAssertNil(f.journal.state().receive, f.model.message)
        let reads = await f.backend.reads; XCTAssertEqual(reads, 1)
        XCTAssertEqual(f.journal.state().baseline?.revision, 7)
    }
    func testCompletionSurvivesForegroundLossAndDoesNotReplay() async throws {
        let f = try await fixture()
        f.model.editor.updateText("완료"); await f.model.save(); await f.model.prepare(); await f.model.send()
        let message = f.model.message
        await f.model.setForeground(false)
        XCTAssertEqual(f.model.message, message); XCTAssertFalse(f.model.prepared)
        XCTAssertEqual(try NormalEditorJournal(root: f.journal.root).state().message, message)
        await f.model.setForeground(true); await f.model.prepare(); await f.model.send()
        let writes = await f.backend.requests; XCTAssertEqual(writes.count, 1)
    }
    func testEmptyLocalBodyIsPreservedButNeverTransmitted() async throws {
        let f = try await fixture()
        f.model.editor.updateText(""); await f.model.save(); await f.model.prepare(); await f.model.send()
        XCTAssertEqual(try Data(contentsOf: f.file).count, 0)
        let writes = await f.backend.requests; XCTAssertEqual(writes.count, 0)
        f.model.editor.updateText("다시 작성"); await f.model.save(); await f.model.prepare(); await f.model.send()
        XCTAssertEqual(f.journal.state().saves.last?.phase, .completed, f.model.message)
    }
    func testCRRejectedWithoutTrimmingOrAlteringOriginal() async throws {
        let f = try await fixture()
        f.model.editor.updateText("CR\r\n본문"); await f.model.save()
        XCTAssertEqual(try Data(contentsOf: f.file), Data(normalInitial.utf8))
        XCTAssertEqual(try f.journal.draft()?.text, "CR\r\n본문")
    }
    func testOtherDocumentAndStructureMutationsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try NormalEditorJournal(root: root)
        XCTAssertThrowsError(try journal.record(.init(batchID: UUID(), projectID: NormalEditorPlan.local, localTransactionID: nil,
            mutations: [.treeOrder(operationID: UUID(), content: "[]", generation: 1)])))
        let batch = normalBatch("본문")
        try journal.record(batch)
        XCTAssertThrowsError(try journal.record(normalBatch("다른 바이트", batch: batch.batchID)))
        XCTAssertEqual(journal.state().saves.count, 1)
    }
    func testRecordCorruptionStopsInsteadOfResettingCompletedHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try NormalEditorJournal(root: root)
        try journal.record(normalBatch("본문"))
        let file = root.appendingPathComponent("000000000001.record")
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try NormalEditorJournal(root: root))
        XCTAssertEqual(try Data(contentsOf: file), Data("broken".utf8))
    }
    func testGenericReceiptAcceptsNewOperationAndRejectsTampering() throws {
        let request = try SyncV2Contract.buildDocumentCommitRequest(projectID: UUID(), projectSyncMode: .idBased, migrationEpoch: 1,
            writerDeviceID: UUID(), documentID: UUID(), intentKind: .update, baseRevision: 12, parentFolderID: UUID(),
            name: "자유 원고.txt", content: "자유 문장 e\u{301}🙂", isDeleted: false, structureRevision: 1)
        let project = UUID(uuidString: request.json.objectValue!["project_id"]!.stringValue!)!
        let pending = SyncV2PendingContractBatch(localProjectID: .init(rawValue: UUID()), serverProjectID: project, request: request)
        let user = UUID(), response = makeGeneralCommitResponseForTesting(pending)
        let receipt = try makeGeneralCommitReceiptForTesting(pending, accountID: user, response: response)
        XCTAssertEqual(try receipt.validatedResponse(for: pending, accountID: user), response)
        XCTAssertThrowsError(try receipt.validatedResponse(for: pending, accountID: UUID()))
        var batch = receipt.batch.objectValue!; batch["request_sha256"] = .string(String(repeating: "0", count: 64))
        XCTAssertThrowsError(try SyncV2GeneralCommitReceipt(batch: .object(batch), result: receipt.result).validatedResponse(for: pending, accountID: user))
    }
}

private actor NormalTestWorkspace: WorkspaceStateRepository {
    func lastProjectID() -> ProjectID? { nil }
    func setLastProjectID(_ projectID: ProjectID?) {}
    func editorState(for projectID: ProjectID) -> EditorWorkspaceState {
        .init(projectID: projectID, left: .init(documentID: nil, cursor: .start), right: nil, activePane: .left)
    }
    func saveEditorState(_ state: EditorWorkspaceState) {}
    func binderWidth(for projectID: ProjectID) -> Double { 280 }
    func setBinderWidth(_ width: Double, for projectID: ProjectID) {}
    func expandedFolderIDs(in projectID: ProjectID) -> Set<DocumentID> { [] }
    func setExpanded(_ isExpanded: Bool, for folderID: DocumentID) {}
    func cursor(for documentID: DocumentID) -> TextCursorState { .start }
    func saveCursor(_ cursor: TextCursorState, for documentID: DocumentID) {}
}

private struct NormalTestIdentity: DeviceIdentityProviding {
    let id = DeviceIdentifier(uuid: UUID())
    func currentState() async -> DeviceIdentityState { .ready(id) }
    func currentIdentifier() async throws -> DeviceIdentifier { id }
    func prepareIdentity() async {}
}
private struct NormalTestAuth: AuthenticationServicing {
    let user: UUID
    let contractEpoch: SyncV2ContractEpoch? = SyncV2ContractEpoch()
    func currentState() async -> AuthenticationState { .authenticated(.init(userID: user, maskedEmail: nil)) }
    func generalValidationBearer() async throws -> String { "Bearer isolated-test-token" }
    func restoreSession() async -> AuthenticationState { await currentState() }
    func refreshSession(force: Bool) async -> AuthenticationState { await currentState() }
    func signIn(email: String, password: String) async -> AuthenticationState { await currentState() }
    func signOut() async -> AuthenticationState { .signedOut(.userInitiated) }
}
private actor NormalWireStub {
    var structure: SyncV2PreparationSnapshot
    var afterManifest: (@Sendable () -> Void)?
    var nextStructure: SyncV2PreparationSnapshot?
    let user: UUID
    var writes = 0
    var receiptReads = 0
    var lose = false
    var snapshot = normalSnapshot()
    var storedReceipt: SyncV2GeneralCommitReceipt?
    var metadataReads = 0
    init(structure: SyncV2PreparationSnapshot, user: UUID) { self.structure = structure; self.user = user }
    func loseNextResponse() { lose = true }
    func editRemotely(_ text: String) { snapshot = normalSnapshot(text, revision: snapshot.revision + 1) }
    func changeAfterNextManifest(to structure: SyncV2PreparationSnapshot) { nextStructure = structure }
    func runAfterNextManifest(_ action: @escaping @Sendable () -> Void) { afterManifest = action }
    func exchange(_ request: URLRequest) throws -> (Data, URLResponse) {
        let path = request.url!.lastPathComponent
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        let selection = query.first { $0.name == "select" }?.value ?? ""
        if ["folders", "tree_orders", "documents"].contains(path) { metadataReads += 1 }
        let result: SyncV2JSON
        switch path {
        case "get_sync_handshake":
            result = .object(["supported": .bool(true), "project_id": .string(NormalEditorPlan.server.uuidString.lowercased()),
                "project_sync_mode": .string("ID_BASED"), "migration_epoch": .int(1), "contract_version": .string(SyncV2Contract.version),
                "canonical_contract_sha256": .string(SyncV2Contract.canonicalSHA256), "server_contract_sha256": .string(SyncV2Contract.canonicalSHA256),
                "server_protocol_version": .int(SyncV2Contract.syncProtocolVersion), "supported_protocol_versions": .array([.int(SyncV2Contract.syncProtocolVersion)]),
                "server_capabilities": .array(SyncV2Contract.requiredServerCapabilities.sorted().map(SyncV2JSON.string))])
        case "folders": result = .array(structure.folders)
        case "tree_orders": result = .array(structure.treeOrders)
        case "documents":
            if selection.contains("content,") {
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                result = .array([try JSONDecoder().decode(SyncV2JSON.self, from: encoder.encode(snapshot))])
            } else {
                result = .array(structure.documents.map { row in
                    var values = row.objectValue!
                    if values["document_id"] == .string(NormalEditorPlan.document.uuidString.lowercased()) { values["revision"] = .int(Int(snapshot.revision)) }
                    return .object(values)
                })
                if let nextStructure { structure = nextStructure; self.nextStructure = nil }
                let action = afterManifest; afterManifest = nil; action?()
            }
        case "document_commit":
            let envelope = try JSONDecoder().decode(SyncV2JSON.self, from: request.httpBody!)
            let contract = try SyncV2ContractRequest(storedJSON: envelope.objectValue!["p_request"]!)
            let pending = SyncV2PendingContractBatch(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server, request: contract)
            result = makeGeneralCommitResponseForTesting(pending)
            storedReceipt = try makeGeneralCommitReceiptForTesting(pending, accountID: user, response: result)
            snapshot = normalSnapshot(contract.orderedIntents[0].objectValue!["payload"]!.objectValue!["content"]!.stringValue!, revision: snapshot.revision + 1)
            writes += 1
            if lose { lose = false; throw URLError(.networkConnectionLost) }
        case "sync_batches": receiptReads += 1; result = .array(storedReceipt.map { [$0.batch] } ?? [])
        case "sync_batch_results": receiptReads += 1; result = .array(storedReceipt.map { [$0.result] } ?? [])
        default: throw NormalEditorError.request
        }
        let data = try JSONEncoder().encode(result)
        let count = result.arrayValue?.count ?? 1
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Range": count == 0 ? "*/0" : "0-\(count - 1)/\(count)"])!)
    }
}

extension NormalEditorTests {
    private struct StructureLiveFixture {
        let base: Fixture
        let raw: SyncV2Store
        let wire: NormalWireStub
        let backend: LiveNormalEditorBackend
        let policy: ReceiveValidationPolicy
    }
    private func structureLiveFixture() async throws -> StructureLiveFixture {
        let f = try await fixture(), url = f.root.appendingPathComponent("structure.sqlite"), user = UUID()
        let metadata = normalStructure(), unrestricted = ReceiveValidationPolicy(enabled: false, configuration: nil)
        let scope = GeneralSyncValidationScope(restricted: false, selection: nil)
        let raw: SyncV2Store = try await ReceiveValidationPolicy.$override.withValue(unrestricted) {
            try await GeneralSyncValidationScope.$override.withValue(scope) {
                guard case let .available(store) = await SyncV2Store.open(at: url) else { throw NormalEditorError.storage }
                try await store.save(ProjectSyncBinding.connected(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server,
                    kind: .existingServerProject, projectName: "합성", ownerSubject: user))
                for row in metadata.documents {
                    let d = row.objectValue!, id = UUID(uuidString: d["document_id"]!.stringValue!)!
                    let snapshot = SyncV2RemoteDocumentSnapshot(documentID: id, relativePath: d["relative_path"]!.stringValue!,
                        content: id == NormalEditorPlan.document ? normalInitial : "다른 시험 본문", revision: Int64(d["revision"]!.intValue!),
                        isDeleted: false, deletedAt: nil, updatedAt: Date(), parentFolderID: UUID(uuidString: d["parent_folder_id"]!.stringValue!),
                        name: d["name"]!.stringValue!, structureRevision: 1)
                    _ = try await store.applySnapshotBaseline(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server, snapshot: snapshot, expectedRevision: nil)
                    try await store.adoptContractManifestMetadata(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server, entries: [snapshot.manifestEntry])
                }
                let folders: [SyncV2RemoteFolder] = metadata.folders.map { row in
                    let f = row.objectValue!
                    return .init(folderID: UUID(uuidString: f["folder_id"]!.stringValue!)!, parentFolderID: f["parent_folder_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                        name: f["name"]!.stringValue!, revision: 1, isDeleted: false, updatedAt: Date())
                }
                try await store.applyFolderSnapshotBaselines(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server, folders: folders, excluding: [])
                let orders: [SyncV2RemoteTreeOrder] = metadata.treeOrders.map { row in
                    let f = row.objectValue!
                    return .init(treeOrderID: UUID(uuidString: f["tree_order_id"]!.stringValue!)!, parentFolderID: f["parent_folder_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                        children: f["children"]!.arrayValue!.map { UUID(uuidString: $0.stringValue!)! }, revision: Int64(f["revision"]!.intValue!), updatedAt: Date())
                }
                try await store.applyTreeOrderSnapshotBaselines(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server, treeOrders: orders)
                return store
            }
        }
        let wire = NormalWireStub(structure: normalStructure(expanded: true), user: user)
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(),
            endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: user), network: { try await wire.exchange($0) })
        let key = ContractPathGate.storageKey(for: NormalEditorPlan.local), prior = UserDefaults.standard.object(forKey: ContractPathGate.storageKey(for: NormalEditorPlan.local))
        ContractPathGate.setOpen(true, for: NormalEditorPlan.local)
        addTeardownBlock { if let prior { UserDefaults.standard.set(prior, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let repository = NormalTestRepository()
        await repository.addFolders(root: UUID(uuidString: "e87a0e44-9a8d-4b18-b974-b40f4ab1eaad")!)
        let backend = LiveNormalEditorBackend(store: LazySyncV2ProjectBindingStore(databaseURL: url, deviceIdentityProvider: NormalTestIdentity()),
            documents: repository, local: f.local,
            applier: LocalSyncV2SnapshotApplier(documentRepository: repository, workspaceLocator: FixedWorkspaceLocator(root: f.root.appendingPathComponent("workspace"))),
            mutationGate: SyncV2DocumentMutationGate(), auth: NormalTestAuth(user: user),
            configuration: .init(url: URL(string: ReceiveValidationPolicy.Configuration.staging)!, publishableKey: "isolated-public-key"),
            journal: f.journal, bindingEpoch: SyncV2ContractEpoch(), projectEpoch: SyncV2ContractEpoch())
        let text = "갱신 뒤 같은 A 요청"
        f.model.editor.updateText(text); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text, point: .beforeHTTP)) { await f.model.prepare() }
        return .init(base: f, raw: raw, wire: wire, backend: backend, policy: policy)
    }
    func testLiveStructureRefreshKeepsSQLiteAndSourceAndReachesSameBeforeHTTPCheckpoint() async throws {
        let f = try await structureLiveFixture(), before = f.base.journal.state()
        let stored = try await f.raw.normalEditorStructure(), baseline = try await f.raw.normalEditorBaseline()
        try await ReceiveValidationPolicy.$override.withValue(f.policy) {
            try await f.backend.prepare()
            do { _ = try await f.backend.remote(); XCTFail("stale structure must stop") } catch { XCTAssertEqual(error as? NormalEditorError, .target) }
            try await f.backend.refreshStructureReference()
            let remote = try await f.backend.remote()
            XCTAssertEqual(remote.revision, 6)
            let after = f.base.journal.state()
            XCTAssertEqual(try stableJSON(before.saves), try stableJSON(after.saves))
            XCTAssertEqual(try stableJSON(before.recoveryRuns), try stableJSON(after.recoveryRuns))
            let actualStored = try await f.raw.normalEditorStructure(), actualBase = try await f.raw.normalEditorBaseline()
            XCTAssertEqual(actualStored, stored); XCTAssertEqual(actualBase.content, baseline.content); XCTAssertEqual(actualBase.revision, baseline.revision)
            let source = after.saves[0].source, request = try await f.backend.freeze(source)
            try f.base.journal.update("requestFrozen") { $0.saves[0].request = request.json; $0.saves[0].requestHash = try request.json.sha256Hex(); $0.saves[0].phase = .frozen }
            do { _ = try await f.backend.transmit(request, willStart: { XCTFail("HTTP must not start") }); XCTFail("checkpoint required") }
            catch { XCTAssertEqual(error as? NormalEditorError, .recoveryCheckpoint) }
            XCTAssertEqual(request.batchID, source.batchID)
            let writes = await f.wire.writes; XCTAssertEqual(writes, 0)
            let reopened = try NormalEditorJournal(root: f.base.journal.root)
            XCTAssertNotNil(reopened.state().structureReference)
            XCTAssertEqual(reopened.state().recoveryCheckpoints?.count, 1)
        }
    }
    func testLiveStructureRefreshRejectsRemoteBodyChangeWithoutPublishingReference() async throws {
        let f = try await structureLiveFixture()
        await f.wire.editRemotely("외부 본문 변경")
        try await ReceiveValidationPolicy.$override.withValue(f.policy) {
            try await f.backend.prepare()
            do { try await f.backend.refreshStructureReference(); XCTFail("changed base") }
            catch { XCTAssertEqual(error as? NormalEditorError, .baseline) }
        }
        XCTAssertNil(f.base.journal.state().structureReference)
    }
    func testLiveStructureRefreshRejectsChangingMetadataAndRevokedAuthority() async throws {
        for revoke in [false, true] {
            let f = try await structureLiveFixture()
            try await ReceiveValidationPolicy.$override.withValue(f.policy) {
                try await f.backend.prepare()
                if revoke { await f.wire.runAfterNextManifest { [policy = f.policy] in policy.invalidate() } }
                else { await f.wire.changeAfterNextManifest(to: normalStructure()) }
                do { try await f.backend.refreshStructureReference(); XCTFail("must stop") } catch {}
            }
            XCTAssertNil(f.base.journal.state().structureReference)
            XCTAssertEqual(f.base.journal.state().saves[0].phase, .queued)
            let writes = await f.wire.writes; XCTAssertEqual(writes, 0)
        }
    }
    private func stableJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func queueSQL(_ f: StructureLiveFixture, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(f.base.root.appendingPathComponent("structure.sqlite").path, &db) == SQLITE_OK else { throw NormalEditorError.storage }
        defer { sqlite3_close_v2(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw NormalEditorError.storage }
    }
    private func seedRetirementPair(_ f: StructureLiveFixture) throws {
        let ids = NormalEditorTestQueueRetirement.sources.keys.sorted()
        for (i, id) in ids.enumerated() {
            let text = "iPad 보존 초안" + (i == 0 ? "" : "\n")
            let source = LocalMutationBatch(batchID: UUID(uuidString: id)!, projectID: NormalEditorPlan.local, localTransactionID: nil,
                mutations: [.documentSnapshot(operationID: UUID(uuidString: i == 0 ? "61dea381-b0da-4f74-b26f-1576f0596830" : "c4e299ab-fdac-416f-938c-5af2e0dd2899")!,
                    documentID: .init(rawValue: UUID(uuidString: "955ff845-aa32-4f10-956e-bac83501b205")!),
                    relativePath: .init(rawValue: "메인/메모장/통합검증 20260913/B/왕복.txt"), content: text,
                    contentHash: ContentHash(rawValue: NormalEditorPlan.hash(text))!, localSaveGeneration: i == 0 ? 202205561220666 : 202207460207500, isDeleted: false)])
            let json = String(decoding: try stableJSON(source), as: UTF8.self)
            XCTAssertEqual(NormalEditorPlan.hash(json), NormalEditorTestQueueRetirement.sources[id])
            try queueSQL(f, """
                INSERT INTO sync_contract_local_batches(batch_id,local_project_id,project_id,source_json,writer_device_id,project_sync_mode,
                    migration_epoch,contract_version,contract_sha256,protocol_version,client_build_id,status,created_at)
                VALUES ('\(id)','\(NormalEditorPlan.local.rawValue.uuidString.lowercased())','\(NormalEditorPlan.server.uuidString.lowercased())',
                    '\(json.replacingOccurrences(of: "'", with: "''"))','00000000-0000-4000-8000-000000000001','ID_BASED',1,
                    '\(SyncV2Contract.version)','\(SyncV2Contract.canonicalSHA256)',\(SyncV2Contract.syncProtocolVersion),'isolated-test','waiting','2026-09-13T05:32:36Z');
                """)
        }
    }
    private func checkpointDuplicateFixture() async throws -> StructureLiveFixture {
        let f = try await structureLiveFixture()
        try await ReceiveValidationPolicy.$override.withValue(f.policy) {
            try await f.backend.prepare(); try await f.backend.refreshStructureReference()
            let request = try await f.backend.freeze(f.base.journal.state().saves[0].source)
            try f.base.journal.update("requestFrozen") {
                $0.saves[0].request = request.json; $0.saves[0].requestHash = try request.json.sha256Hex(); $0.saves[0].phase = .frozen
            }
            do { _ = try await f.backend.transmit(request, willStart: { XCTFail("before HTTP") }); XCTFail("checkpoint") }
            catch { XCTAssertEqual(error as? NormalEditorError, .recoveryCheckpoint) }
        }
        try f.base.journal.record(normalBatch(try NormalEditorPlan.content(f.base.journal.state().saves[0].source)))
        await f.backend.invalidate()
        return f
    }
    func testCheckpointDuplicateReconciliationPreservesRequestAndResumesExactlyOnce() async throws {
        let f = try await checkpointDuplicateFixture(), before = f.base.journal.state()
        let original = before.saves[0], request = try SyncV2ContractRequest(storedJSON: XCTUnwrap(original.request))
        let detail = try await f.raw.generalRecoveryDetail(localProjectID: NormalEditorPlan.local, batchID: original.source.batchID)
        let oldFiles = try FileManager.default.contentsOfDirectory(at: f.base.journal.root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "record" }
        let oldBytes = try oldFiles.map { try Data(contentsOf: $0) }
        try await f.backend.reconcileDuplicateSaves()
        var expected = before; expected.saves[1].phase = .superseded
        XCTAssertEqual(try stableJSON(f.base.journal.state()), try stableJSON(expected))
        XCTAssertEqual(try oldFiles.map { try Data(contentsOf: $0) }, oldBytes)
        let after = try await f.raw.generalRecoveryDetail(localProjectID: NormalEditorPlan.local, batchID: original.source.batchID)
        XCTAssertEqual(after.sourceJSON, detail.sourceJSON); XCTAssertEqual(after.requestJSON, detail.requestJSON)
        XCTAssertEqual(after.responseJSON, detail.responseJSON); XCTAssertEqual(after.row, detail.row)
        let reopened = try NormalEditorJournal(root: f.base.journal.root)
        XCTAssertNil(NormalEditorDuplicateSaveResolution(reopened.state()))
        let text = try NormalEditorPlan.content(original.source), baseline = try await f.raw.normalEditorBaseline()
        try NormalEditorRecoveryInjection.preflight(journal: reopened, baseline: baseline, localText: text,
            dirty: false, composing: false, draftFailed: false)
        var writes = await f.wire.writes; XCTAssertEqual(writes, 0)
        try await ReceiveValidationPolicy.$override.withValue(f.policy) {
            try await f.backend.prepare()
            let resumed = try await f.backend.freeze(original.source)
            XCTAssertEqual(resumed, request)
            let response = try await f.backend.transmit(resumed) {
                try f.base.journal.update("httpStarted") { $0.saves[0].phase = .httpStarted; $0.saves[0].attempts.append(UUID()) }
            }
            try f.base.journal.update("responseStored") { $0.saves[0].response = response; $0.saves[0].phase = .responseStored }
            try await f.backend.complete(resumed, response: response)
        }
        writes = await f.wire.writes; XCTAssertEqual(writes, 1)
        let finalBase = try await f.raw.normalEditorBaseline()
        XCTAssertEqual(finalBase.revision, baseline.revision + 1); XCTAssertEqual(finalBase.content, text)
    }
    func testCheckpointDuplicateReconciliationRejectsUncertainOrChangedJournal() async throws {
        let f = try await checkpointDuplicateFixture(), original = f.base.journal.state()
        XCTAssertNotNil(NormalEditorDuplicateSaveResolution(original))
        for mode in 0..<9 {
            var state = original
            switch mode {
            case 0: state.saves[0].phase = .httpStarted
            case 1: state.saves[0].attempts = [UUID()]
            case 2: state.saves[0].response = .object([:])
            case 3: state.saves[0].requestHash = String(repeating: "0", count: 64)
            case 4: state.recoveryCheckpoints = []
            case 5: state.saves[1].request = state.saves[0].request
            case 6: state.saves[1].attempts = [UUID()]
            case 7: state.saves[1] = .init(source: normalBatch("different content"))
            default: state.recoveryRuns![0].completed = true
            }
            XCTAssertNil(NormalEditorDuplicateSaveResolution(state), "mode \(mode)")
        }
    }
    func testCheckpointDuplicateReconciliationRejectsSQLiteDriftWithoutChangingJournal() async throws {
        for sql in [
            "UPDATE sync_contract_batches SET attempts=2;",
            "UPDATE sync_contract_batches SET response_json='{}';",
            "UPDATE sync_contract_batches SET status='completed';",
            "UPDATE sync_contract_batches SET request_json='{}';",
            "UPDATE sync_contract_local_batches SET source_json='{}';",
            "UPDATE sync_contract_operations SET status='completed',result_revision=7;",
            "UPDATE sync_contract_operations SET payload_json='{}';",
            "UPDATE sync_contract_operations SET base_revision=8;",
            "UPDATE sync_contract_batches SET next_attempt_at='2099-01-01';"
        ] {
            let f = try await checkpointDuplicateFixture()
            try queueSQL(f, sql)
            let before = try stableJSON(f.base.journal.state())
            do { try await f.backend.reconcileDuplicateSaves(); XCTFail("must reject drift") } catch {}
            XCTAssertEqual(try stableJSON(f.base.journal.state()), before)
            let writes = await f.wire.writes; XCTAssertEqual(writes, 0)
        }
    }
    func testCheckpointDuplicateReconciliationRejectsMaterializedFollowerAndDirtyDraft() async throws {
        for dirtyDraft in [false, true] {
            let f = try await checkpointDuplicateFixture()
            if dirtyDraft { try f.base.journal.saveDraft(text: "new draft", cursor: .start) }
            else {
                let follower = f.base.journal.state().saves[1].source.batchID.uuidString.lowercased()
                try queueSQL(f, """
                    INSERT INTO sync_contract_batches(batch_id,local_project_id,project_id,request_json,batch_payload_sha256,status,created_at,updated_at)
                    SELECT '\(follower)',local_project_id,project_id,request_json,batch_payload_sha256,'completed',created_at,updated_at FROM sync_contract_batches;
                    """)
            }
            let before = try stableJSON(f.base.journal.state())
            do { try await f.backend.reconcileDuplicateSaves(); XCTFail("unsafe follower/draft") } catch {}
            XCTAssertEqual(try stableJSON(f.base.journal.state()), before)
        }
    }
    func testDuplicateReconciliationKeepsOriginalRunAndAllowsTestRetirementThenSameCheckpoint() async throws {
        let f = try await structureLiveFixture(); try seedRetirementPair(f)
        try await ReceiveValidationPolicy.$override.withValue(f.policy) {
            try await f.backend.prepare(); try await f.backend.refreshStructureReference()
        }
        try f.base.journal.update("freezeStarted") { $0.saves[0].phase = .freezing }
        let original = f.base.journal.state().saves[0].source, text = try NormalEditorPlan.content(original)
        try f.base.journal.record(normalBatch(text))
        let before = f.base.journal.state(), metadata = try await f.raw.normalEditorStructure()
        let staleQueue = try await f.raw.normalEditorActiveQueueIDs()
        await f.backend.invalidate() // No login/handshake/prepared authority for local reconciliation.
        try await f.backend.reconcileDuplicateSaves()
        let after = f.base.journal.state()
        XCTAssertEqual(after.saves.map(\.source), before.saves.map(\.source))
        XCTAssertEqual(after.saves[0].phase, .freezing); XCTAssertEqual(after.saves[1].phase, .superseded)
        XCTAssertEqual(after.recoveryRuns, before.recoveryRuns)
        XCTAssertEqual(try stableJSON(after.baseline), try stableJSON(before.baseline))
        XCTAssertEqual(try stableJSON(after.structureReference), try stableJSON(before.structureReference))
        let actualMetadata = try await f.raw.normalEditorStructure(), actualQueue = try await f.raw.normalEditorActiveQueueIDs()
        XCTAssertEqual(actualMetadata, metadata); XCTAssertEqual(actualQueue, staleQueue)
        XCTAssertEqual(try String(contentsOf: f.base.file, encoding: .utf8), text)
        let reopened = try NormalEditorJournal(root: f.base.journal.root)
        XCTAssertEqual(reopened.state().saves[1].phase, .superseded)
        XCTAssertNil(NormalEditorDuplicateSaveResolution(reopened.state()))
        try await ReceiveValidationPolicy.$override.withValue(f.policy) {
            try await f.backend.prepare(); try await f.backend.retireUnsentTestQueue()
            let request = try await f.backend.freeze(original)
            XCTAssertEqual(request.batchID, original.batchID)
            try f.base.journal.update("requestFrozen") { $0.saves[0].request = request.json; $0.saves[0].requestHash = try request.json.sha256Hex(); $0.saves[0].phase = .frozen }
            do { _ = try await f.backend.transmit(request, willStart: { XCTFail("no HTTP") }); XCTFail("checkpoint") }
            catch { XCTAssertEqual(error as? NormalEditorError, .recoveryCheckpoint) }
        }
        let writes = await f.wire.writes; XCTAssertEqual(writes, 0)
    }
    func testDuplicateReconciliationRejectsAnySQLiteQueueHistoryForEitherSource() async throws {
        for index in [0, 1] {
            for completed in [false, true] {
                let f = try await structureLiveFixture(); try seedRetirementPair(f)
                try f.base.journal.update("freezeStarted") { $0.saves[0].phase = .freezing }
                try f.base.journal.record(normalBatch(try NormalEditorPlan.content(f.base.journal.state().saves[0].source)))
                let before = try stableJSON(f.base.journal.state()), batch = f.base.journal.state().saves[index].source.batchID.uuidString.lowercased()
                try queueSQL(f, """
                    INSERT INTO sync_contract_local_batches(batch_id,local_project_id,project_id,source_json,writer_device_id,project_sync_mode,
                        migration_epoch,contract_version,contract_sha256,protocol_version,client_build_id,status,created_at)
                    SELECT '\(batch)',local_project_id,project_id,source_json,writer_device_id,project_sync_mode,migration_epoch,
                        contract_version,contract_sha256,protocol_version,client_build_id,'\(completed ? "completed" : "waiting")',created_at
                    FROM sync_contract_local_batches LIMIT 1;
                    """)
                do { try await f.backend.reconcileDuplicateSaves(); XCTFail("SQLite source already exists") }
                catch { XCTAssertEqual(error as? NormalEditorError, .queue) }
                XCTAssertEqual(try stableJSON(f.base.journal.state()), before)
            }
        }
    }
    func testDuplicateReconciliationRejectsLocalTextDraftAndBaselineDrift() async throws {
        for mode in 0..<3 {
            let f = try await structureLiveFixture()
            try f.base.journal.update("freezeStarted") { $0.saves[0].phase = .freezing }
            try f.base.journal.record(normalBatch(try NormalEditorPlan.content(f.base.journal.state().saves[0].source)))
            switch mode {
            case 0: try Data("다른 실제 파일".utf8).write(to: f.base.file)
            case 1: try f.base.journal.saveDraft(text: "다른 초안", cursor: .start)
            default: try queueSQL(f, "UPDATE sync_documents SET server_revision=7 WHERE document_id='\(NormalEditorPlan.document.uuidString.lowercased())';")
            }
            let before = try stableJSON(f.base.journal.state())
            do { try await f.backend.reconcileDuplicateSaves(); XCTFail("drift \(mode)") } catch {}
            XCTAssertEqual(try stableJSON(f.base.journal.state()), before)
        }
    }
    func testDuplicateReconciliationRejectsStoredRequestOrReusedOperationWithoutLocalQueueRow() async throws {
        for reuseOperation in [false, true] {
            let f = try await structureLiveFixture()
            try f.base.journal.update("freezeStarted") { $0.saves[0].phase = .freezing }
            try f.base.journal.record(normalBatch(try NormalEditorPlan.content(f.base.journal.state().saves[0].source)))
            let source = f.base.journal.state().saves[1].source
            guard case let .documentSnapshot(operation, _, _, _, _, _, _) = source.mutations[0] else { return XCTFail("source") }
            let batch = (reuseOperation ? UUID() : source.batchID).uuidString.lowercased()
            try queueSQL(f, """
                INSERT INTO sync_contract_batches(batch_id,local_project_id,project_id,request_json,batch_payload_sha256,status,created_at,updated_at)
                VALUES ('\(batch)','\(NormalEditorPlan.local.rawValue.uuidString.lowercased())','\(NormalEditorPlan.server.uuidString.lowercased())',
                    '{}','\(String(repeating: "0", count: 64))','completed','2026-09-22','2026-09-22');
                """)
            if reuseOperation {
                try queueSQL(f, """
                    INSERT INTO sync_contract_operations(operation_id,batch_id,sequence,entity_kind,entity_id,intent_kind,base_revision,payload_json,payload_sha256,status,created_at,updated_at)
                    VALUES ('\(operation.uuidString.lowercased())','\(batch)',1,'document','\(NormalEditorPlan.document.uuidString.lowercased())','update',6,'{}',
                        '\(String(repeating: "0", count: 64))','completed','2026-09-22','2026-09-22');
                    """)
            }
            let before = try stableJSON(f.base.journal.state())
            do { try await f.backend.reconcileDuplicateSaves(); XCTFail("request history") }
            catch { XCTAssertEqual(error as? NormalEditorError, .queue) }
            XCTAssertEqual(try stableJSON(f.base.journal.state()), before)
        }
    }
    func testDuplicateReconciliationRejectsStalePlanAndCheckFailureWithoutJournalMutation() async throws {
        let f = try await structureLiveFixture()
        try f.base.journal.update("freezeStarted") { $0.saves[0].phase = .freezing }
        let text = try NormalEditorPlan.content(f.base.journal.state().saves[0].source)
        try f.base.journal.record(normalBatch(text))
        let plan = try XCTUnwrap(NormalEditorDuplicateSaveResolution(f.base.journal.state()))
        let before = try stableJSON(f.base.journal.state())
        do {
            try await f.raw.reconcileNormalEditorDuplicateSaves(plan, journal: f.base.journal, localText: text) { throw NormalEditorError.locked }
            XCTFail("check failed")
        } catch { XCTAssertEqual(error as? NormalEditorError, .locked) }
        XCTAssertEqual(try stableJSON(f.base.journal.state()), before)
        try f.base.journal.record(normalBatch(text)) // replaces the queued follower with a new identity
        let latest = try stableJSON(f.base.journal.state())
        do { try await f.raw.reconcileNormalEditorDuplicateSaves(plan, journal: f.base.journal, localText: text, check: {}); XCTFail("stale") }
        catch { XCTAssertEqual(error as? NormalEditorError, .queue) }
        XCTAssertEqual(try stableJSON(f.base.journal.state()), latest)
    }
    func testTestQueueRetirementPreservesSourcesAndRunAndReachesBeforeHTTP() async throws {
        let f = try await structureLiveFixture()
        try seedRetirementPair(f)
        let ids = NormalEditorTestQueueRetirement.sources.keys.sorted().map { UUID(uuidString: $0)! }
        var originals: [String] = []
        for id in ids { originals.append(try await f.raw.generalRecoveryDetail(localProjectID: NormalEditorPlan.local, batchID: id).sourceJSON) }
        let before = f.base.journal.state(), local = try await f.raw.normalEditorStructure(), text = try String(contentsOf: f.base.file, encoding: .utf8)
        try await ReceiveValidationPolicy.$override.withValue(f.policy) {
            try await f.backend.prepare()
            try await f.backend.refreshStructureReference()
            let source = before.saves[0].source
            do { _ = try await f.backend.freeze(source); XCTFail("other waiting work must block") }
            catch { XCTAssertEqual(error as? NormalEditorError, .queue) }
            try f.base.journal.update("freezeStarted") { $0.saves[0].phase = .freezing }
            try await f.backend.retireUnsentTestQueue()
            try await f.backend.retireUnsentTestQueue() // Idempotent after a crash before the UI message.
            for (i, id) in ids.enumerated() {
                let detail = try await f.raw.generalRecoveryDetail(localProjectID: NormalEditorPlan.local, batchID: id)
                XCTAssertEqual(detail.sourceJSON, originals[i]); XCTAssertEqual(detail.row.sourceStatus, "completed")
                XCTAssertEqual(detail.row.errorCode, NormalEditorTestQueueRetirement.marker)
                XCTAssertNil(detail.requestJSON); XCTAssertNil(detail.responseJSON)
            }
            XCTAssertEqual(f.base.journal.state().saves[0].source, source)
            XCTAssertEqual(f.base.journal.state().recoveryRuns, before.recoveryRuns)
            let stored = try await f.raw.normalEditorStructure(); XCTAssertEqual(stored, local)
            XCTAssertEqual(try String(contentsOf: f.base.file, encoding: .utf8), text)
            let request = try await f.backend.freeze(source)
            try f.base.journal.update("requestFrozen") { $0.saves[0].request = request.json; $0.saves[0].requestHash = try request.json.sha256Hex(); $0.saves[0].phase = .frozen }
            do { _ = try await f.backend.transmit(request, willStart: { XCTFail("must stop before network") }); XCTFail("checkpoint") }
            catch { XCTAssertEqual(error as? NormalEditorError, .recoveryCheckpoint) }
            let writes = await f.wire.writes; XCTAssertEqual(writes, 0)
        }
    }
    func testTestQueueRetirementRejectsChangedSourceAndRollsBackBothRows() async throws {
        let f = try await structureLiveFixture(); try seedRetirementPair(f)
        let ids = NormalEditorTestQueueRetirement.sources.keys.sorted()
        try queueSQL(f, "UPDATE sync_contract_local_batches SET source_json=source_json || ' ' WHERE batch_id='\(ids[1])';")
        try await ReceiveValidationPolicy.$override.withValue(f.policy) {
            try await f.backend.prepare()
            do { try await f.backend.retireUnsentTestQueue(); XCTFail("changed source") }
            catch { XCTAssertEqual(error as? NormalEditorError, .queue) }
        }
        for id in ids {
            let detail = try await f.raw.generalRecoveryDetail(localProjectID: NormalEditorPlan.local, batchID: UUID(uuidString: id)!)
            XCTAssertEqual(detail.row.sourceStatus, "waiting"); XCTAssertNil(detail.resolutionJSON)
        }
    }
    func testTestQueueRetirementRejectsOtherWorkAndDependenciesAndMaterializedRows() async throws {
        for mode in 0..<5 {
            let f = try await structureLiveFixture(); try seedRetirementPair(f)
            let id = NormalEditorTestQueueRetirement.sources.keys.sorted()[0]
            switch mode {
            case 0: try queueSQL(f, "UPDATE sync_contract_local_batches SET status='materialized' WHERE batch_id='\(id)';")
            case 1: try queueSQL(f, "UPDATE sync_contract_local_batches SET parent_batch_id='\(id)' WHERE batch_id<>'\(id)';")
            case 2: try queueSQL(f, "UPDATE sync_contract_local_batches SET batch_id='00000000-0000-4000-8000-000000000099' WHERE batch_id='\(id)';")
            case 3: try f.base.journal.update("checkpoint") { $0.recoveryCheckpoints = [NormalEditorRecoveryInjection.checkpointKey($0.recoveryRuns!.last!.configuration)] }
            default: try queueSQL(f, """
                INSERT INTO sync_contract_batches(batch_id,local_project_id,project_id,request_json,batch_payload_sha256,status,created_at,updated_at)
                SELECT batch_id,local_project_id,project_id,'{}','\(String(repeating: "0", count: 64))','completed',created_at,created_at
                FROM sync_contract_local_batches WHERE batch_id='\(id)';
                """)
            }
            try await ReceiveValidationPolicy.$override.withValue(f.policy) {
                try await f.backend.prepare()
                do { try await f.backend.retireUnsentTestQueue(); XCTFail("unsafe retirement \(mode)") }
                catch { XCTAssertEqual(error as? NormalEditorError, .queue) }
            }
            let writes = await f.wire.writes; XCTAssertEqual(writes, 0)
        }
    }
    func testCompletedRecoveryHistoryDoesNotBlockFreezeEvenBeyondOnePage() async throws {
        let f = try await structureLiveFixture(); try seedRetirementPair(f)
        try queueSQL(f, "UPDATE sync_contract_local_batches SET status='completed',last_error_code='EXPANDED_CONTRACT_PLAN';")
        for _ in 0..<55 {
            try queueSQL(f, """
                INSERT INTO sync_contract_local_batches(batch_id,local_project_id,project_id,source_json,writer_device_id,project_sync_mode,
                    migration_epoch,contract_version,contract_sha256,protocol_version,client_build_id,status,created_at,last_error_code)
                SELECT '\(UUID().uuidString.lowercased())',local_project_id,project_id,source_json,writer_device_id,project_sync_mode,
                    migration_epoch,contract_version,contract_sha256,protocol_version,client_build_id,'completed',created_at,'EXPANDED_CONTRACT_PLAN'
                FROM sync_contract_local_batches LIMIT 1;
                """)
        }
        let page = try await f.raw.generalRecoveryPage(localProjectID: NormalEditorPlan.local, after: nil)
        XCTAssertNotNil(page.nextCursor)
        try await ReceiveValidationPolicy.$override.withValue(f.policy) {
            try await f.backend.prepare()
            let request = try await f.backend.freeze(f.base.journal.state().saves[0].source)
            XCTAssertEqual(request.batchID, f.base.journal.state().saves[0].source.batchID)
        }
    }
    func testTestQueueRetirementRejectsRevokedAuthorityWithoutMutation() async throws {
        let f = try await structureLiveFixture(); try seedRetirementPair(f)
        try await ReceiveValidationPolicy.$override.withValue(f.policy) {
            try await f.backend.prepare(); f.policy.invalidate()
            do { try await f.backend.retireUnsentTestQueue(); XCTFail("revoked") } catch {}
        }
        let ids = try await f.raw.normalEditorActiveQueueIDs()
        XCTAssertEqual(Set(ids.map { $0.uuidString.lowercased() }), Set(NormalEditorTestQueueRetirement.sources.keys))
        let writes = await f.wire.writes; XCTAssertEqual(writes, 0)
    }
    func testPreparedRunCancellationRecoversAfterDurableResaveWithoutRewritingHistory() async throws {
        let f = try await fixture(), first = "준비된 본문", second = "다시 저장한 본문"
        let config = runConfiguration(first)
        f.model.editor.updateText(first); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(config) { await f.model.prepare() }
        XCTAssertTrue(f.model.prepared)
        let bound = try XCTUnwrap(f.journal.state().recoveryRuns?.last?.batchID)
        f.model.editor.updateText(second); await f.model.save()
        await f.model.prepare()
        XCTAssertFalse(f.model.prepared)
        XCTAssertEqual(f.journal.state().saves.first?.phase, .superseded)
        // Restoring the same bytes is also a distinct durable save; never silently rebind it.
        f.model.editor.updateText(first); await f.model.save()
        await f.model.prepare()
        XCTAssertFalse(f.model.prepared)
        let saves = try stableJSON(f.journal.state().saves)
        let files = try FileManager.default.contentsOfDirectory(at: f.journal.root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "record" }
        let bytes = try files.map { try Data(contentsOf: $0) }
        let draft = try Data(contentsOf: f.journal.root.appendingPathComponent("draft.json"))
        await f.model.cancelPreparedRecoveryRun()
        XCTAssertFalse(f.model.prepared)
        XCTAssertEqual(f.journal.state().recoveryRuns?.last?.cancelled, true)
        XCTAssertEqual(f.journal.state().recoveryRuns?.last?.completed, false)
        XCTAssertEqual(f.journal.state().recoveryRuns?.last?.batchID, bound)
        XCTAssertEqual(try stableJSON(f.journal.state().saves), saves)
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, bytes)
        XCTAssertEqual(try Data(contentsOf: f.journal.root.appendingPathComponent("draft.json")), draft)
        XCTAssertEqual(try Data(contentsOf: f.file), Data(first.utf8))
        let reopened = try NormalEditorJournal(root: f.journal.root)
        XCTAssertEqual(reopened.state().recoveryRuns?.last?.cancelled, true)
        XCTAssertThrowsError(try NormalEditorRecoveryInjection.effectiveConfiguration(reopened))
        // No launch environment, a runless config, or a reused UUID must not bypass diagnostics.
        await f.model.prepare(); XCTAssertFalse(f.model.prepared)
        for invalid in [config, .init(point: .afterStoredResponse, contentHash: NormalEditorPlan.hash(first))] {
            await NormalEditorRecoveryInjection.$testConfiguration.withValue(invalid) { await f.model.prepare() }
            XCTAssertFalse(f.model.prepared)
        }
        let next = runConfiguration(first)
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(next) { await f.model.prepare() }
        XCTAssertTrue(f.model.prepared, f.model.message)
        XCTAssertEqual(f.journal.state().recoveryRuns?.count, 2)
        XCTAssertNotEqual(f.journal.state().recoveryRuns?.last?.batchID, bound)
        // New run is durable too: no launch environment is needed to resume it.
        await f.model.send(); await f.model.prepare(); await f.model.recoverResult()
        XCTAssertEqual(f.journal.state().recoveryRuns?.last?.completed, true, f.model.message)
        XCTAssertEqual(f.journal.state().recoveryRuns?.first?.cancelled, true)
        let requests = await f.backend.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.batchID, f.journal.state().saves.last?.source.batchID)
    }
    func testPreparedRunCancellationAfterAutosaveDoesNotSendOrAcquireAuthority() async throws {
        let f = try await fixture(autosave: .milliseconds(20))
        f.model.editor.updateText("첫 저장"); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration("첫 저장")) { await f.model.prepare() }
        f.model.editor.updateText("자동 저장")
        for _ in 0..<100 where f.journal.state().saves.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(f.journal.state().saves.count, 2)
        await f.model.cancelPreparedRecoveryRun()
        XCTAssertEqual(f.journal.state().recoveryRuns?.last?.cancelled, true)
        XCTAssertFalse(f.model.prepared)
        let prepares = await f.backend.prepares, requests = await f.backend.requests, reads = await f.backend.reads
        let backendPrepared = await f.backend.prepared
        XCTAssertEqual(prepares, 1); XCTAssertTrue(requests.isEmpty); XCTAssertEqual(reads, 0); XCTAssertFalse(backendPrepared)
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration("자동 저장")) { await f.model.prepare() }
        XCTAssertTrue(f.model.prepared, f.model.message)
    }
    func testCancellationRejectsAllMaterializedSendPhasesWithoutChangingJournal() async throws {
        for phase: NormalEditorJournal.Phase in [.freezing, .frozen, .httpStarted, .responseStored] {
            let f = try await fixture(), text = "취소 금지"
            f.model.editor.updateText(text); await f.model.save()
            await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text)) { await f.model.prepare() }
            let request = try await f.backend.freeze(f.journal.state().saves[0].source)
            try f.journal.update("testMaterializedPhase") { state in
                state.saves[0].phase = phase
                if phase != .freezing {
                    state.saves[0].request = request.json; state.saves[0].requestHash = try request.json.sha256Hex()
                }
                if phase == .httpStarted || phase == .responseStored { state.saves[0].attempts = [UUID()] }
                if phase == .responseStored { state.saves[0].response = .object([:]) }
            }
            let before = try stableJSON(f.journal.state())
            let files = try FileManager.default.contentsOfDirectory(atPath: f.journal.root.path).sorted()
            XCTAssertFalse(NormalEditorRecoveryInjection.canCancelPreparedRun(f.journal.state()))
            XCTAssertThrowsError(try NormalEditorRecoveryInjection.cancelPreparedRun(f.journal))
            XCTAssertEqual(try stableJSON(f.journal.state()), before)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.journal.root.path).sorted(), files)
            await f.model.cancelPreparedRecoveryRun()
            XCTAssertFalse(f.model.prepared)
            XCTAssertTrue(f.journal.state().recoveryRuns?.last?.isActive == true)
            XCTAssertEqual(f.journal.state().saves[0].phase, phase)
        }
    }
    func testCancellationRechecksRequestMarkersAndCheckpointEvenOnQueuedSource() async throws {
        let f = try await fixture(), text = "요청 표식"
        f.model.editor.updateText(text); await f.model.save()
        let config = runConfiguration(text)
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(config) { await f.model.prepare() }
        let state = f.journal.state()
        for marker in 0..<5 {
            var unsafe = state
            switch marker {
            case 0: unsafe.saves[0].request = .object([:])
            case 1: unsafe.saves[0].requestHash = "recorded"
            case 2: unsafe.saves[0].response = .object([:])
            case 3: unsafe.saves[0].attempts = [UUID()]
            default: unsafe.recoveryCheckpoints = [NormalEditorRecoveryInjection.checkpointKey(config)]
            }
            XCTAssertFalse(NormalEditorRecoveryInjection.canCancelPreparedRun(unsafe))
        }
    }
    func testReceivePreparationCanCancelButStoredOrPartialReceiveCannot() async throws {
        for phase in [nil, "responseStored", "originalApplyStarted"] as [String?] {
            let f = try await fixture()
            await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration("수신 본문", point: .afterOriginalApply)) {
                await f.model.prepare()
            }
            if let phase {
                try f.journal.update("testReceiveStarted") {
                    $0.receive = .init(id: UUID(), baseline: normalSnapshot(), remote: normalSnapshot("수신 본문", revision: 7), phase: phase)
                }
                let before = try stableJSON(f.journal.state())
                XCTAssertThrowsError(try NormalEditorRecoveryInjection.cancelPreparedRun(f.journal))
                XCTAssertEqual(try stableJSON(f.journal.state()), before)
            } else {
                await f.model.cancelPreparedRecoveryRun()
                XCTAssertEqual(f.journal.state().recoveryRuns?.last?.cancelled, true)
            }
            let reads = await f.backend.reads, requests = await f.backend.requests
            XCTAssertEqual(reads, 0); XCTAssertTrue(requests.isEmpty)
        }
    }
    func testCancellationIsExplicitAndCannotRunInBackgroundOrCompleteCancelledRun() async throws {
        let f = try await fixture(), text = "명시 취소"
        f.model.editor.updateText(text); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text)) { await f.model.prepare() }
        let model = f.model
        await f.backend.onNextBaseline { await model.cancelPreparedRecoveryRun() }
        await model.prepare()
        XCTAssertTrue(model.prepared); XCTAssertNil(f.journal.state().recoveryRuns?.last?.cancelled)
        await f.model.setForeground(false)
        let before = try stableJSON(f.journal.state())
        await f.model.cancelPreparedRecoveryRun()
        XCTAssertEqual(try stableJSON(f.journal.state()), before)
        await f.model.setForeground(true); await f.model.cancelPreparedRecoveryRun()
        var cancelled = f.journal.state()
        NormalEditorRecoveryInjection.completeRun(&cancelled)
        XCTAssertEqual(cancelled.recoveryRuns?.last?.completed, false)
        XCTAssertThrowsError(try NormalEditorRecoveryInjection.cancelPreparedRun(f.journal))
    }
    func testPreparedRunCanBeCancelledAfterSessionReconstruction() async throws {
        let f = try await fixture()
        f.model.editor.updateText("이전 저장"); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration("이전 저장")) { await f.model.prepare() }
        f.model.editor.updateText("새 저장"); await f.model.save()
        await f.model.setForeground(false)
        let journal = try NormalEditorJournal(root: f.journal.root), repository = NormalTestRepository()
        let product = LocalDocumentStore(workspaceLocator: FixedWorkspaceLocator(root: f.root.appendingPathComponent("workspace")),
            metadataUpdater: RecordingMetadataUpdater(), durableChangeRecorder: NormalEditorRecorder(journal: journal))
        let local = NormalEditorDocumentStore(local: product, journal: journal)
        let editor = EditorSessionModel(documentRepository: repository, documentStore: local,
            workspaceStateRepository: NormalTestWorkspace(), preserveDraft: { _, text, cursor in try journal.saveDraft(text: text, cursor: cursor) },
            autosaveDelay: .seconds(3600))
        let model = NormalEditorSession(editor: editor, journal: journal, backend: f.backend, documents: repository)
        await model.open(); await model.prepare()
        XCTAssertTrue(model.opened); XCTAssertFalse(model.prepared)
        await model.cancelPreparedRecoveryRun()
        XCTAssertEqual(journal.state().recoveryRuns?.last?.cancelled, true)
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration("새 저장")) { await model.prepare() }
        XCTAssertTrue(model.prepared, model.message)
        XCTAssertEqual(journal.state().recoveryRuns?.count, 2)
    }
    func testCancellationPreservesUnsavedDraftAndRequiresCleanNewRun() async throws {
        let f = try await fixture()
        f.model.editor.updateText("저장 본문"); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration("저장 본문")) { await f.model.prepare() }
        f.model.editor.updateText("미저장 초안 e\u{301}🙂\n")
        let draft = try Data(contentsOf: f.journal.root.appendingPathComponent("draft.json"))
        await f.model.cancelPreparedRecoveryRun()
        XCTAssertTrue(f.model.editor.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: f.journal.root.appendingPathComponent("draft.json")), draft)
        XCTAssertEqual(try Data(contentsOf: f.file), Data("저장 본문".utf8))
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration("저장 본문")) { await f.model.prepare() }
        XCTAssertFalse(f.model.prepared)
        XCTAssertEqual(f.journal.state().recoveryRuns?.count, 1)
    }
    func testRecoveryRunWithoutCancellationFieldStillDecodesAsActive() throws {
        let legacy = NormalEditorJournal.RecoveryRun(configuration: runConfiguration("이전 실행"), batchID: UUID())
        let bytes = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("cancelled"))
        let decoded = try JSONDecoder().decode(NormalEditorJournal.RecoveryRun.self, from: bytes)
        XCTAssertTrue(decoded.isActive); XCTAssertNil(decoded.cancelled)
    }
    private func runConfiguration(_ text: String, point: NormalEditorRecoveryInjection.Point = .afterStoredResponse,
                                  id: UUID = UUID(), revision: Int64 = 6, baseline: String = normalInitial) -> NormalEditorRecoveryInjection.Configuration {
        .init(point: point, contentHash: NormalEditorPlan.hash(text),
              run: .init(id: id, baselineRevision: revision, baselineHash: NormalEditorPlan.hash(baseline)))
    }
    func testRunConfigurationRequiresCompleteCanonicalIdentityAndBaseline() throws {
        let valid = ["WRITERPAD_RECOVERY_PLAN": NormalEditorRecoveryInjection.plan,
                     "WRITERPAD_RECOVERY_POINT": "afterStoredResponse",
                     "WRITERPAD_RECOVERY_CONTENT_SHA256": NormalEditorPlan.initialHash,
                     "WRITERPAD_RECOVERY_RUN_ID": UUID().uuidString.lowercased(),
                     "WRITERPAD_RECOVERY_BASE_REVISION": "6",
                     "WRITERPAD_RECOVERY_BASE_SHA256": NormalEditorPlan.initialHash]
        XCTAssertNotNil(try NormalEditorRecoveryInjection.parse(valid)?.run)
        for key in valid.keys {
            var invalid = valid; invalid.removeValue(forKey: key)
            XCTAssertThrowsError(try NormalEditorRecoveryInjection.parse(invalid), key)
        }
        for (key, value) in [("WRITERPAD_RECOVERY_RUN_ID", "../escape"),
                             ("WRITERPAD_RECOVERY_BASE_REVISION", "06"),
                             ("WRITERPAD_RECOVERY_BASE_REVISION", "5"),
                             ("WRITERPAD_RECOVERY_BASE_REVISION", String(Int64.max)),
                             ("WRITERPAD_RECOVERY_BASE_SHA256", "invalid")] {
            var invalid = valid; invalid[key] = value
            XCTAssertThrowsError(try NormalEditorRecoveryInjection.parse(invalid))
        }
    }
    func testRunPreparationDoesNotAcquireAuthorityAfterSceneDeactivationDuringLocalRead() async throws {
        let f = try await fixture(), text = "비활성 전환 준비"
        f.model.editor.updateText(text); await f.model.save()
        let model = f.model
        await f.backend.onNextBaseline { await model.setForeground(false) }
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text)) { await model.prepare() }
        let prepares = await f.backend.prepares
        XCTAssertEqual(prepares, 0); XCTAssertFalse(model.prepared)
        XCTAssertEqual(f.journal.state().saves.last?.phase, .queued)
    }
    func testRunRechecksDraftAfterPreparationBeforeRemoteRead() async throws {
        let f = try await fixture(), text = "준비한 저장"
        f.model.editor.updateText(text); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text)) { await f.model.prepare() }
        XCTAssertTrue(f.model.prepared)
        f.model.editor.updateText("준비 이후의 미저장 변경")
        await f.model.send()
        let reads = await f.backend.reads, requests = await f.backend.requests
        XCTAssertEqual(reads, 0); XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(f.model.prepared)
    }
    func testRunAllowsAcknowledgedBaselineBeforeFinalJournalCompletion() async throws {
        let f = try await fixture(), text = "완료 기록 직전"
        f.model.editor.updateText(text); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text)) { await f.model.prepare(); await f.model.send() }
        let save = f.journal.state().saves[0]
        let request = try SyncV2ContractRequest(storedJSON: XCTUnwrap(save.request))
        await f.backend.prepare()
        try await f.backend.complete(request, response: XCTUnwrap(save.response))
        // Durable store advanced, append-only journal still has the old baseline/responseStored.
        await f.model.prepare(); await f.model.recoverResult()
        XCTAssertEqual(f.journal.state().saves[0].phase, .completed, f.model.message)
        XCTAssertEqual(f.journal.state().baseline?.revision, 7)
        let requests = await f.backend.requests
        XCTAssertEqual(requests.count, 1)
    }
    func testRunPreflightRejectsWrongBaselineAndDirtyInputBeforeAuthority() async throws {
        let f = try await fixture(), text = "준비 검사🙂\n"
        f.model.editor.updateText(text); await f.model.save()
        let source = try XCTUnwrap(f.journal.state().saves.last?.source)
        for configuration in [runConfiguration(text, revision: 7), runConfiguration(text, baseline: "wrong"), runConfiguration("wrong body")] {
            await NormalEditorRecoveryInjection.$testConfiguration.withValue(configuration) { await f.model.prepare() }
            XCTAssertFalse(f.model.prepared)
        }
        f.model.editor.updateText("미저장 초안")
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text)) { await f.model.prepare() }
        let prepares = await f.backend.prepares
        XCTAssertEqual(prepares, 0); XCTAssertNil(f.journal.state().recoveryRuns)
        XCTAssertEqual(f.journal.state().saves.last?.source, source)
    }
    func testRunRejectsWrongTargetAndCompositionWithoutWritingJournal() async throws {
        let f = try await fixture()
        let before = try FileManager.default.contentsOfDirectory(atPath: f.journal.root.path).sorted()
        let wrong = SyncV2RemoteDocumentSnapshot(documentID: UUID(), relativePath: NormalEditorPlan.path,
            content: normalInitial, revision: 6, isDeleted: false, deletedAt: nil, updatedAt: Date(),
            parentFolderID: NormalEditorPlan.parent, name: GeneralValidationPlan.name, structureRevision: 1)
        try NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration("수신", point: .afterOriginalApply)) {
            for (base, composing, failed) in [(wrong, false, false), (normalSnapshot(), true, false), (normalSnapshot(), false, true)] {
                XCTAssertThrowsError(try NormalEditorRecoveryInjection.preflight(journal: f.journal,
                    baseline: base, localText: normalInitial, dirty: false, composing: composing, draftFailed: failed))
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.journal.root.path).sorted(), before)
    }
    func testRunCannotReplaceUncertainRequestAndReopensWithoutLaunchEnvironment() async throws {
        let f = try await fixture(), text = "불변 요청 e\u{301}\n", config = runConfiguration("불변 요청 e\u{301}\n")
        f.model.editor.updateText(text); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(config) {
            await f.model.prepare(); await f.model.send()
        }
        XCTAssertEqual(f.journal.state().saves[0].phase, .responseStored)
        let source = f.journal.state().saves[0]
        let reopened = try NormalEditorJournal(root: f.journal.root)
        XCTAssertEqual(try NormalEditorRecoveryInjection.effectiveConfiguration(reopened), config)
        for replacement in [runConfiguration(text), .init(point: .afterStoredResponse, contentHash: NormalEditorPlan.hash(text))] {
            await NormalEditorRecoveryInjection.$testConfiguration.withValue(replacement) { await f.model.prepare() }
            XCTAssertFalse(f.model.prepared)
        }
        XCTAssertEqual(f.journal.state().saves[0].source, source.source)
        XCTAssertEqual(f.journal.state().saves[0].requestHash, source.requestHash)
        XCTAssertEqual(f.journal.state().saves[0].attempts, source.attempts)
        // No launch configuration: the persisted run still selects the same checkpoint/operation.
        await f.model.prepare(); await f.model.recoverResult()
        XCTAssertEqual(f.journal.state().saves[0].phase, .completed, f.model.message)
        XCTAssertEqual(f.journal.state().recoveryRuns?.last?.completed, true)
        let writes = await f.backend.requests, reads = await f.backend.receiptReads
        XCTAssertEqual(writes.count, 1); XCTAssertEqual(reads, 0)
    }
    func testDistinctRunsConsumeSamePointOnceEachWithoutRewritingOldRecords() async throws {
        let f = try await fixture(), first = "첫 실행\n", second = "다음 실행\n"
        let config1 = runConfiguration(first)
        f.model.editor.updateText(first); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(config1) { await f.model.prepare(); await f.model.send() }
        await f.model.prepare(); await f.model.recoverResult()
        let oldRecords = try FileManager.default.contentsOfDirectory(at: f.journal.root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "record" }
        let bytes = try oldRecords.map { try Data(contentsOf: $0) }
        f.model.editor.updateText(second); await f.model.save()
        let config2 = runConfiguration(second, revision: 7, baseline: first)
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(config2) { await f.model.prepare(); await f.model.send() }
        XCTAssertEqual(f.journal.state().saves.last?.phase, .responseStored, f.model.message)
        XCTAssertEqual(Set(f.journal.state().recoveryCheckpoints ?? []),
            Set([NormalEditorRecoveryInjection.checkpointKey(config1), NormalEditorRecoveryInjection.checkpointKey(config2)]))
        XCTAssertEqual(try oldRecords.map { try Data(contentsOf: $0) }, bytes)
        await f.model.prepare(); await f.model.recoverResult()
        XCTAssertEqual(f.journal.state().recoveryRuns?.count, 2)
        XCTAssertTrue(f.journal.state().recoveryRuns?.allSatisfy(\.completed) == true)
        let writes = await f.backend.requests
        XCTAssertEqual(writes.count, 2)
        XCTAssertNotEqual(writes[0].batchID, writes[1].batchID)
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(config1) { await f.model.prepare() }
        XCTAssertFalse(f.model.prepared)
    }
    func testNewRunCannotAdoptLegacyFrozenRequest() async throws {
        let f = try await fixture(), text = "기존 동결 요청"
        f.model.editor.updateText(text); await f.model.save(); await f.model.prepare()
        await f.backend.configure(before: true); await f.model.send()
        let request = f.journal.state().saves[0].request
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text)) { await f.model.prepare() }
        XCTAssertFalse(f.model.prepared); XCTAssertNil(f.journal.state().recoveryRuns)
        XCTAssertEqual(f.journal.state().saves[0].request, request)
    }
    func testReceiveRunRejectsQueuedSaveBeforeAuthorityWithoutCompletingIt() async throws {
        let f = try await fixture()
        f.model.editor.updateText("잘못 저장한 본문"); await f.model.save()
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration("받을 본문", point: .afterOriginalApply)) {
            await f.model.prepare(); await f.model.receive()
        }
        let prepares = await f.backend.prepares, requests = await f.backend.requests
        XCTAssertEqual(prepares, 0); XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(f.journal.state().saves.last?.phase, .queued)
        XCTAssertNil(f.journal.state().receive); XCTAssertNil(f.journal.state().recoveryRuns)
    }
    func testReceiveRunRejectsUnexpectedRemoteBeforeOriginalApply() async throws {
        let f = try await fixture(), text = "승인된 수신 본문"
        await f.backend.setRemote("다른 본문", revision: 7)
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text, point: .afterOriginalApply)) {
            await f.model.prepare(); await f.model.receive()
        }
        XCTAssertEqual(try Data(contentsOf: f.file), Data(normalInitial.utf8))
        XCTAssertNil(f.journal.state().receive)
        XCTAssertFalse(f.model.prepared)
        await f.backend.setRemote(text, revision: 6)
        await f.model.prepare(); await f.model.receive()
        XCTAssertNil(f.journal.state().receive)
        XCTAssertEqual(try Data(contentsOf: f.file), Data(normalInitial.utf8))
    }
    func testReceiveRunResumesPartialOriginalUsingStoredRemoteWithoutSend() async throws {
        let f = try await fixture(), text = "수신 중단 복구🙂\n"
        await f.backend.setRemote(text, revision: 7)
        await f.backend.configure(apply: true)
        await NormalEditorRecoveryInjection.$testConfiguration.withValue(runConfiguration(text, point: .afterOriginalApply)) {
            await f.model.prepare(); await f.model.receive()
        }
        let receive = try XCTUnwrap(f.journal.state().receive)
        XCTAssertEqual(receive.phase, "originalApplyStarted")
        XCTAssertEqual(try Data(contentsOf: f.file), Data(text.utf8))
        let reopened = try NormalEditorJournal(root: f.journal.root)
        XCTAssertEqual(reopened.state().receive?.id, receive.id)
        await f.backend.configure()
        await f.model.prepare(); await f.model.recoverResult() // Wrong direction cannot send/complete.
        XCTAssertNotNil(f.journal.state().receive)
        await f.model.prepare(); await f.model.receive()
        XCTAssertNil(f.journal.state().receive, f.model.message)
        XCTAssertEqual(f.journal.state().baseline?.revision, 7)
        XCTAssertEqual(try f.journal.draft()?.text, text)
        XCTAssertEqual(f.journal.state().recoveryRuns?.last?.completed, true)
        let requests = await f.backend.requests, reads = await f.backend.reads
        XCTAssertTrue(requests.isEmpty); XCTAssertEqual(reads, 1)
    }
    func testRealContractQueueAndReceiptRecoveryUseSameOperation() async throws {
        let f = try await fixture()
        let url = f.root.appendingPathComponent("sync.sqlite")
        let user = UUID(), identity = NormalTestIdentity(), mainFolder = UUID()
        let unrestricted = ReceiveValidationPolicy(enabled: false, configuration: nil)
        let scope = GeneralSyncValidationScope(restricted: false, selection: nil)
        let raw: SyncV2Store = try await ReceiveValidationPolicy.$override.withValue(unrestricted) {
            try await GeneralSyncValidationScope.$override.withValue(scope) {
                guard case let .available(store) = await SyncV2Store.open(at: url) else { throw NormalEditorError.storage }
                try await store.save(ProjectSyncBinding.connected(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server,
                    kind: .existingServerProject, projectName: "합성", ownerSubject: user))
                _ = try await store.applySnapshotBaseline(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server,
                    snapshot: normalSnapshot(), expectedRevision: nil)
                try await store.adoptContractManifestMetadata(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server,
                    entries: [normalSnapshot().manifestEntry])
                let root = mainFolder
                try await store.applyFolderSnapshotBaselines(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server,
                    folders: [.init(folderID: root, parentFolderID: nil, name: "메인", revision: 1, isDeleted: false, updatedAt: Date()),
                              .init(folderID: NormalEditorPlan.parent, parentFolderID: root, name: "원고", revision: 1, isDeleted: false, updatedAt: Date())], excluding: [])
                try await store.applyTreeOrderSnapshotBaselines(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server,
                    treeOrders: [.init(treeOrderID: UUID(uuidString: "31eb06be-9cc9-55db-9a05-5882172474ce")!, parentFolderID: NormalEditorPlan.parent,
                        children: [NormalEditorPlan.document], revision: 2, updatedAt: Date())])
                return store
            }
        }
        let wire = NormalWireStub(structure: try await raw.normalEditorStructure(), user: user)
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(),
            endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: user), network: { try await wire.exchange($0) })
        let key = ContractPathGate.storageKey(for: NormalEditorPlan.local)
        let prior = UserDefaults.standard.object(forKey: key)
        ContractPathGate.setOpen(true, for: NormalEditorPlan.local)
        defer { if let prior { UserDefaults.standard.set(prior, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let lazy = LazySyncV2ProjectBindingStore(databaseURL: url, deviceIdentityProvider: identity)
        let repository = NormalTestRepository()
        await repository.addFolders(root: mainFolder)
        let backend = LiveNormalEditorBackend(store: lazy, documents: repository, local: f.local,
            applier: LocalSyncV2SnapshotApplier(documentRepository: repository, workspaceLocator: FixedWorkspaceLocator(root: f.file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())),
            mutationGate: SyncV2DocumentMutationGate(), auth: NormalTestAuth(user: user),
            configuration: .init(url: URL(string: ReceiveValidationPolicy.Configuration.staging)!, publishableKey: "isolated-public-key"),
            journal: f.journal, bindingEpoch: SyncV2ContractEpoch(), projectEpoch: SyncV2ContractEpoch())
        try await ReceiveValidationPolicy.$override.withValue(policy) {
            try await backend.prepare()
            let remote = try await backend.remote(); XCTAssertEqual(remote.revision, 6)
            f.model.editor.updateText("새 자유 원고 e\u{301}🙂\n"); await f.model.save()
            let source = try XCTUnwrap(f.journal.state().saves.last?.source)
            let request = try await backend.freeze(source)
            try NormalEditorPlan.validate(request, source: source)
            try f.journal.update("testFreeze") {
                $0.saves[0].request = request.json; $0.saves[0].requestHash = try request.json.sha256Hex(); $0.saves[0].phase = .frozen
            }
            await wire.loseNextResponse()
            do { _ = try await backend.transmit(request, willStart: {
                try f.journal.update("testHTTPStarted") { $0.saves[0].phase = .httpStarted }
            }); XCTFail("lost response") } catch {}
            await backend.invalidate(); try await backend.prepare()
            let recovered = try await backend.receipt(request)
            let response = try XCTUnwrap(recovered)
            try await backend.complete(request, response: response)
            try await backend.complete(request, response: response) // idempotent late local completion
            let base = try await backend.localBaseline()
            XCTAssertEqual(base.revision, 7); XCTAssertEqual(Data(base.content.utf8), Data("새 자유 원고 e\u{301}🙂\n".utf8))
            let queue = try await lazy.generalQueueStatus(localProjectID: NormalEditorPlan.local)
            XCTAssertEqual(queue.pendingCount, 0)
            let stored = try await lazy.normalEditorPending(batchID: request.batchID)
            XCTAssertEqual(stored?.request, request)
            let writes = await wire.writes, reads = await wire.receiptReads
            XCTAssertEqual(writes, 1); XCTAssertEqual(reads, 2)
            try f.journal.update("testComplete") { $0.saves[0].phase = .completed; $0.baseline = base }
            await wire.editRemotely("실제 수신 반영 원고 e\u{301}🙂")
            let next = try await backend.remote()
            let receive = NormalEditorJournal.Receive(id: UUID(), baseline: base, remote: next)
            try f.journal.update("testReceive") { $0.receive = receive }
            try await backend.apply(receive, willApply: {})
            let applied = try await backend.localBaseline()
            XCTAssertEqual(applied.revision, 8)
            XCTAssertEqual(try Data(contentsOf: f.file), Data(next.content.utf8))
            try await backend.apply(receive, willApply: { XCTFail("completed receive must not apply twice") })
        }
    }
    func testAuthorityIsLocalToActionAndExpiryCannotOpenGlobalSending() async throws {
        let user = UUID(), epoch = SyncV2ContractEpoch()
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(),
            endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: user))
        let ticket = try XCTUnwrap(policy.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging))
        try policy.verifyAccount(user, ticket: ticket); try policy.select(NormalEditorPlan.server)
        let initial = epoch.value
        let authority = NormalEditorAuthority(policy: policy, ticket: ticket, bearer: "Bearer test") {
            guard epoch.value == initial else { throw NormalEditorError.locked }
        }
        try authority.bind()
        XCTAssertFalse(policy.sendingAllowed)
        XCTAssertThrowsError(try policy.requireSending())
        try await authority.mutate(sending: true) { try policy.requireSending() }
        XCTAssertThrowsError(try policy.requireSending())
        epoch.advance()
        do { try await authority.mutate(sending: true) { try policy.requireSending() }; XCTFail("expired") } catch {}
        XCTAssertFalse(policy.sendingAllowed)
    }
}

extension NormalEditorTests {
    func testSelfHashedArbitraryRPCAndUnscopedReceiptAreDenied() async throws {
        let f = try await fixture(), user = UUID()
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(),
            endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: user))
        let ticket = try XCTUnwrap(policy.beginAuthentication(foreground: true, endpoint: ReceiveValidationPolicy.Configuration.staging))
        try policy.verifyAccount(user, ticket: ticket); try policy.select(NormalEditorPlan.server)
        let authority = NormalEditorAuthority(policy: policy, ticket: ticket, bearer: "Bearer test", journal: f.journal, check: {})
        try authority.bind()
        for path in ["rpc/document_commit", "rpc/atomic_structure_commit", "sync_batch_results?select=*&batch_id=eq.fake&limit=2"] {
            var request = URLRequest(url: URL(string: ReceiveValidationPolicy.Configuration.staging + "/rest/v1/" + path)!)
            request.httpMethod = path.hasPrefix("rpc/") ? "POST" : "GET"
            request.setValue("Bearer test", forHTTPHeaderField: "Authorization")
            request.setValue("count=exact", forHTTPHeaderField: "Prefer")
            let frozen = request
            try await authority.context {
                try NormalEditorAuthority.$wireHash.withValue(GeneralSyncValidationScope.fingerprint(frozen)) {
                    XCTAssertThrowsError(try policy.authorize(frozen, ticket: ticket))
                }
            }
        }
    }
    func testFreezingMarkerProtectsOperationBeforeRequestPersistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try NormalEditorJournal(root: root), first = normalBatch("고정 중 원고")
        try journal.record(first)
        try journal.update("freezeStarted") { $0.saves[0].phase = .freezing }
        let reopened = try NormalEditorJournal(root: root)
        try reopened.record(normalBatch("후속 편집"))
        XCTAssertEqual(reopened.state().head, 0)
        XCTAssertEqual(reopened.state().saves[0].source, first)
        XCTAssertEqual(reopened.state().saves[0].phase, .freezing)
    }
}

extension NormalEditorTests {
    func testUnpublishedTornRecordDoesNotHideDurableDraftOrQueue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try NormalEditorJournal(root: root)
        let batch = normalBatch("저장 본문")
        try journal.record(batch); try journal.saveDraft(text: "최신 초안", cursor: .start)
        let interrupted = root.appendingPathComponent(UUID().uuidString + ".tmp")
        try Data("incomplete unpublished bytes".utf8).write(to: interrupted)
        let reopened = try NormalEditorJournal(root: root)
        XCTAssertEqual(reopened.state().saves.first?.source, batch)
        XCTAssertEqual(try reopened.draft()?.text, "최신 초안")
        XCTAssertTrue(FileManager.default.fileExists(atPath: interrupted.path))
    }
}


extension NormalEditorTests {
    func testRecoveryDiagnosticBoundariesSurviveSessionReconstruction() async throws {
        let f = try await fixture()
        let url = f.root.appendingPathComponent("sync.sqlite")
        let user = UUID(), identity = NormalTestIdentity(), mainFolder = UUID()
        let unrestricted = ReceiveValidationPolicy(enabled: false, configuration: nil)
        let scope = GeneralSyncValidationScope(restricted: false, selection: nil)
        let raw: SyncV2Store = try await ReceiveValidationPolicy.$override.withValue(unrestricted) {
            try await GeneralSyncValidationScope.$override.withValue(scope) {
                guard case let .available(store) = await SyncV2Store.open(at: url) else { throw NormalEditorError.storage }
                try await store.save(ProjectSyncBinding.connected(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server,
                    kind: .existingServerProject, projectName: "합성", ownerSubject: user))
                _ = try await store.applySnapshotBaseline(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server,
                    snapshot: normalSnapshot(), expectedRevision: nil)
                try await store.adoptContractManifestMetadata(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server,
                    entries: [normalSnapshot().manifestEntry])
                let root = mainFolder
                try await store.applyFolderSnapshotBaselines(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server,
                    folders: [.init(folderID: root, parentFolderID: nil, name: "메인", revision: 1, isDeleted: false, updatedAt: Date()),
                              .init(folderID: NormalEditorPlan.parent, parentFolderID: root, name: "원고", revision: 1, isDeleted: false, updatedAt: Date())], excluding: [])
                try await store.applyTreeOrderSnapshotBaselines(localProjectID: NormalEditorPlan.local, serverProjectID: NormalEditorPlan.server,
                    treeOrders: [.init(treeOrderID: UUID(uuidString: "31eb06be-9cc9-55db-9a05-5882172474ce")!, parentFolderID: NormalEditorPlan.parent,
                        children: [NormalEditorPlan.document], revision: 2, updatedAt: Date())])
                return store
            }
        }
        let wire = NormalWireStub(structure: try await raw.normalEditorStructure(), user: user)
        let policy = ReceiveValidationPolicy(enabled: true, configuration: .init(version: 1, revision: UUID(),
            endpoint: ReceiveValidationPolicy.Configuration.staging, accountID: user), network: { try await wire.exchange($0) })
        let key = ContractPathGate.storageKey(for: NormalEditorPlan.local)
        let prior = UserDefaults.standard.object(forKey: key)
        ContractPathGate.setOpen(true, for: NormalEditorPlan.local)
        defer { if let prior { UserDefaults.standard.set(prior, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let lazy = LazySyncV2ProjectBindingStore(databaseURL: url, deviceIdentityProvider: identity)
        let repository = NormalTestRepository()
        await repository.addFolders(root: mainFolder)

        func reopen() async throws -> NormalEditorSession {
            let journal = try NormalEditorJournal(root: f.journal.root)
            let workspace = f.root.appendingPathComponent("workspace")
            let product = LocalDocumentStore(workspaceLocator: FixedWorkspaceLocator(root: workspace),
                metadataUpdater: RecordingMetadataUpdater(), durableChangeRecorder: NormalEditorRecorder(journal: journal))
            let local = NormalEditorDocumentStore(local: product, journal: journal)
            let editor = EditorSessionModel(documentRepository: repository, documentStore: local,
                workspaceStateRepository: NormalTestWorkspace(),
                preserveDraft: { _, text, cursor in try journal.saveDraft(text: text, cursor: cursor) }, autosaveDelay: .seconds(3600))
            let backend = LiveNormalEditorBackend(
                store: LazySyncV2ProjectBindingStore(databaseURL: url, deviceIdentityProvider: identity),
                documents: repository, local: local,
                applier: LocalSyncV2SnapshotApplier(documentRepository: repository, workspaceLocator: FixedWorkspaceLocator(root: workspace)),
                mutationGate: SyncV2DocumentMutationGate(), auth: NormalTestAuth(user: user),
                configuration: .init(url: URL(string: ReceiveValidationPolicy.Configuration.staging)!, publishableKey: "isolated-public-key"),
                journal: journal, bindingEpoch: SyncV2ContractEpoch(), projectEpoch: SyncV2ContractEpoch())
            let model = NormalEditorSession(editor: editor, journal: journal, backend: backend, documents: repository)
            await model.open()
            XCTAssertTrue(model.opened, model.message)
            XCTAssertFalse(model.prepared)
            return model
        }
        try await ReceiveValidationPolicy.$override.withValue(policy) {
            var model = try await reopen()
            let text = "복구 경계 원고 e\u{301}🙂\n", nextText = "부분 수신 원고 e\u{301}🙂\n"
            model.editor.updateText(text); await model.save()
            let source = try XCTUnwrap(model.journal.state().saves.last?.source)
            await model.setForeground(false)
            model = try await reopen()
            XCTAssertEqual(model.editor.currentText, text)
            XCTAssertEqual(model.journal.state().saves.last?.source, source)
            await model.prepare()
            await NormalEditorRecoveryInjection.$testConfiguration.withValue(.init(point: .beforeHTTP, contentHash: NormalEditorPlan.hash(text))) {
                await model.send()
            }
            let frozen = try XCTUnwrap(model.journal.state().saves.last?.requestHash)
            XCTAssertEqual(model.journal.state().saves.last?.phase, .frozen, model.message)
            XCTAssertEqual(model.journal.state().saves.last?.attempts.count, 0)
            var writes = await wire.writes; XCTAssertEqual(writes, 0)
            model = try await reopen(); await model.prepare()
            await NormalEditorRecoveryInjection.$testConfiguration.withValue(.init(point: .afterCommitResponse, contentHash: NormalEditorPlan.hash(text))) {
                await model.send()
            }
            XCTAssertEqual(model.journal.state().saves.last?.phase, .httpStarted, model.message)
            XCTAssertNil(model.journal.state().saves.last?.response)
            XCTAssertEqual(model.journal.state().saves.last?.attempts.count, 1)
            XCTAssertEqual(model.journal.state().saves.last?.requestHash, frozen)
            writes = await wire.writes; XCTAssertEqual(writes, 1)
            model = try await reopen(); await model.prepare()
            await NormalEditorRecoveryInjection.$testConfiguration.withValue(.init(point: .afterStoredResponse, contentHash: NormalEditorPlan.hash(text))) {
                await model.recoverResult()
            }
            XCTAssertEqual(model.journal.state().saves.last?.phase, .responseStored, model.message)
            XCTAssertEqual(model.journal.state().baseline?.revision, 6)
            var reads = await wire.receiptReads; XCTAssertEqual(reads, 2)
            model = try await reopen(); await model.prepare()
            // Same arm is consumed durably; restarting cannot inject it again.
            await NormalEditorRecoveryInjection.$testConfiguration.withValue(.init(point: .afterStoredResponse, contentHash: NormalEditorPlan.hash(text))) {
                await model.recoverResult()
            }
            XCTAssertEqual(model.journal.state().saves.last?.phase, .completed, model.message)
            XCTAssertEqual(model.journal.state().baseline?.revision, 7)
            XCTAssertEqual(model.journal.state().saves.last?.source, source)
            reads = await wire.receiptReads; XCTAssertEqual(reads, 2)
            let completion = model.journal.state().message
            await model.setForeground(false)
            model = try await reopen()
            XCTAssertEqual(model.message, completion)
            await model.prepare()
            XCTAssertEqual(model.journal.state().saves.last?.phase, .completed)
            await wire.editRemotely(nextText)
            await NormalEditorRecoveryInjection.$testConfiguration.withValue(.init(point: .afterOriginalApply, contentHash: NormalEditorPlan.hash(nextText))) {
                await model.receive()
            }
            XCTAssertEqual(model.journal.state().receive?.phase, "originalApplyStarted", model.message)
            XCTAssertEqual(model.journal.state().baseline?.revision, 7)
            XCTAssertEqual(try Data(contentsOf: f.file), Data(nextText.utf8))
            let beforeResumeReads = await wire.metadataReads
            model = try await reopen(); await model.prepare()
            await model.receive()
            let afterResumeReads = await wire.metadataReads
            XCTAssertEqual(afterResumeReads, beforeResumeReads)
            XCTAssertNil(model.journal.state().receive, model.message)
            XCTAssertEqual(model.journal.state().baseline?.revision, 8)
            XCTAssertEqual(model.journal.state().recoveryCheckpoints?.count, 4)
            XCTAssertEqual(try model.journal.draft()?.text, nextText)
            XCTAssertEqual(model.editor.currentText, nextText)
            writes = await wire.writes; reads = await wire.receiptReads
            XCTAssertEqual(writes, 1); XCTAssertEqual(reads, 2)
            let queue = try await lazy.generalQueueStatus(localProjectID: NormalEditorPlan.local)
            XCTAssertEqual(queue.pendingCount, 0)
            // Exercise every run-scoped boundary with the real backend/SQLite and a wire stub.
            // Each run gets a new synthetic save only after the previous one completes.
            for point: NormalEditorRecoveryInjection.Point in [.beforeHTTP, .afterCommitResponse, .afterStoredResponse] {
                let base = try XCTUnwrap(model.journal.state().baseline)
                let content = "실행 격리 \(point.rawValue) e\u{301}🙂\n"
                let configuration = runConfiguration(content, point: point, revision: base.revision, baseline: base.content)
                model.editor.updateText(content); await model.save()
                let beforeWrites = await wire.writes, beforeReceipts = await wire.receiptReads
                await NormalEditorRecoveryInjection.$testConfiguration.withValue(configuration) {
                    await model.prepare(); await model.send()
                }
                let interrupted = try XCTUnwrap(model.journal.state().saves.last)
                XCTAssertEqual(interrupted.phase, point == .beforeHTTP ? .frozen : point == .afterCommitResponse ? .httpStarted : .responseStored, model.message)
                XCTAssertTrue(model.journal.state().recoveryCheckpoints?.contains(NormalEditorRecoveryInjection.checkpointKey(configuration)) == true)
                model = try await reopen(); await model.prepare()
                if point == .beforeHTTP { await model.send() } else { await model.recoverResult() }
                XCTAssertEqual(model.journal.state().saves.last?.phase, .completed, model.message)
                XCTAssertEqual(model.journal.state().saves.last?.source, interrupted.source)
                XCTAssertEqual(model.journal.state().saves.last?.requestHash, interrupted.requestHash)
                XCTAssertEqual(model.journal.state().recoveryRuns?.last?.completed, true)
                let afterWrites = await wire.writes, afterReceipts = await wire.receiptReads
                XCTAssertEqual(afterWrites - beforeWrites, 1)
                XCTAssertEqual(afterReceipts - beforeReceipts, point == .afterCommitResponse ? 2 : 0)
            }
            let runBase = try XCTUnwrap(model.journal.state().baseline), incoming = "실행별 수신 복구\n"
            await wire.editRemotely(incoming)
            let receiveConfiguration = runConfiguration(incoming, point: .afterOriginalApply,
                revision: runBase.revision, baseline: runBase.content)
            await NormalEditorRecoveryInjection.$testConfiguration.withValue(receiveConfiguration) {
                await model.prepare(); await model.receive()
            }
            let receiveID = try XCTUnwrap(model.journal.state().receive?.id)
            XCTAssertTrue(model.journal.state().recoveryCheckpoints?.contains(NormalEditorRecoveryInjection.checkpointKey(receiveConfiguration)) == true)
            let runReads = await wire.metadataReads, runWrites = await wire.writes
            model = try await reopen()
            XCTAssertEqual(model.journal.state().receive?.id, receiveID)
            await model.prepare(); await model.receive()
            XCTAssertNil(model.journal.state().receive, model.message)
            XCTAssertEqual(model.journal.state().baseline?.revision, runBase.revision + 1)
            XCTAssertEqual(try model.journal.draft()?.text, incoming)
            XCTAssertEqual(model.journal.state().recoveryRuns?.count, 4)
            XCTAssertTrue(model.journal.state().recoveryRuns?.allSatisfy(\.completed) == true)
            XCTAssertEqual(model.journal.state().recoveryCheckpoints?.count, 8) // Four legacy + four run-scoped keys.
            let finalReads = await wire.metadataReads, finalWrites = await wire.writes
            XCTAssertEqual(finalReads, runReads); XCTAssertEqual(finalWrites, runWrites)
        }
    }
    func testRecoveryDiagnosticConfigurationFailsClosed() throws {
        XCTAssertNil(try NormalEditorRecoveryInjection.parse([:]))
        XCTAssertThrowsError(try NormalEditorRecoveryInjection.parse(["WRITERPAD_RECOVERY_POINT": "beforeHTTP"]))
        let valid = ["WRITERPAD_RECOVERY_PLAN": NormalEditorRecoveryInjection.plan,
                     "WRITERPAD_RECOVERY_POINT": "beforeHTTP",
                     "WRITERPAD_RECOVERY_CONTENT_SHA256": String(repeating: "a", count: 64)]
        XCTAssertEqual(try NormalEditorRecoveryInjection.parse(valid)?.point, .beforeHTTP)
        for (key, value) in [("WRITERPAD_RECOVERY_PLAN", "old-plan"), ("WRITERPAD_RECOVERY_POINT", "arbitrary"),
                             ("WRITERPAD_RECOVERY_CONTENT_SHA256", "not-a-hash")] {
            var invalid = valid; invalid[key] = value
            XCTAssertThrowsError(try NormalEditorRecoveryInjection.parse(invalid))
        }
    }
    func testRecoveryDiagnosticMismatchDoesNotConsumeOrAlterRequest() async throws {
        let f = try await fixture()
        f.model.editor.updateText("보존 원고\n"); await f.model.save(); await f.model.prepare()
        await f.backend.configure(before: true); await f.model.send()
        let source = f.journal.state().saves[0]
        try NormalEditorRecoveryInjection.$testConfiguration.withValue(.init(point: .beforeHTTP, contentHash: String(repeating: "0", count: 64))) {
            XCTAssertThrowsError(try NormalEditorRecoveryInjection.hit(.beforeHTTP, journal: f.journal)) { error in
                XCTAssertEqual(error as? NormalEditorError, .recoveryConfiguration)
            }
        }
        XCTAssertNil(f.journal.state().recoveryCheckpoints)
        XCTAssertEqual(f.journal.state().saves[0].requestHash, source.requestHash)
        XCTAssertEqual(f.journal.state().saves[0].source, source.source)
        XCTAssertEqual(f.journal.state().saves[0].phase, .frozen)
    }
}


extension NormalEditorTests {
    func testRecoveryReopenRestoresDraftWithoutReplacingQueuedSource() async throws {
        let f = try await fixture()
        f.model.editor.updateText("저장 원고\n"); await f.model.save()
        let source = try XCTUnwrap(f.journal.state().saves.last?.source)
        f.model.editor.updateText("아직 저장하지 않은 초안 e\u{301}🙂\n")
        let journal = try NormalEditorJournal(root: f.journal.root)
        let repository = NormalTestRepository()
        let editor = EditorSessionModel(documentRepository: repository, documentStore: f.local,
            workspaceStateRepository: NormalTestWorkspace(),
            preserveDraft: { _, text, cursor in try journal.saveDraft(text: text, cursor: cursor) }, autosaveDelay: .seconds(3600))
        let model = NormalEditorSession(editor: editor, journal: journal, backend: f.backend, documents: repository)
        await model.open()
        XCTAssertTrue(model.opened, model.message); XCTAssertFalse(model.prepared)
        XCTAssertEqual(Data(model.editor.currentText.utf8), Data("아직 저장하지 않은 초안 e\u{301}🙂\n".utf8))
        XCTAssertEqual(try Data(contentsOf: f.file), Data("저장 원고\n".utf8))
        XCTAssertEqual(journal.state().saves.last?.source, source)
        let writes = await f.backend.requests, reads = await f.backend.reads
        XCTAssertTrue(writes.isEmpty); XCTAssertEqual(reads, 0)
    }
    func testRecoveryDiagnosticUnarmedBoundariesDoNotWriteJournal() async throws {
        let f = try await fixture()
        let before = try FileManager.default.contentsOfDirectory(atPath: f.journal.root.path).sorted()
        for point: NormalEditorRecoveryInjection.Point in [.beforeHTTP, .afterCommitResponse, .afterStoredResponse, .afterOriginalApply] {
            try NormalEditorRecoveryInjection.hit(point, journal: f.journal)
        }
        XCTAssertNil(f.journal.state().recoveryCheckpoints)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.journal.root.path).sorted(), before)
    }
}
