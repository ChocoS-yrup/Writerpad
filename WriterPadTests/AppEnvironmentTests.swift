import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import WriterPad

final class AppEnvironmentTests: XCTestCase {
    @MainActor
    func testWriterPadCommandActionsUpdatesInPlaceWithoutReplacingFocusedIdentity() {
        let actions = WriterPadCommandActions()
        let identity = ObjectIdentifier(actions)
        var receivedCommands: [WriterPadEditorCommand] = []

        actions.update(
            perform: { receivedCommands.append($0) },
            canToggleEditorPane: false
        )
        actions.perform(.save)
        actions.update(
            perform: { receivedCommands.append($0) },
            canToggleEditorPane: true
        )
        actions.perform(.nextChapter)

        XCTAssertEqual(ObjectIdentifier(actions), identity)
        XCTAssertEqual(receivedCommands, [.save, .nextChapter])
        XCTAssertTrue(actions.canToggleEditorPane)
    }

    func testCloudStartupDoesNotRestoreAuthenticationWhenSyncIsDisabled()
        async {
        let authentication = CloudStartupAuthenticationSpy()
        let identity = CloudStartupDeviceIdentitySpy()

        await WriterPadCloudStartup.start(
            syncEnabled: false,
            authenticationService: authentication,
            deviceIdentityService: identity,
            syncDispatcher: nil,
            backgroundSyncCoordinator: nil
        )

        let restoreCalls = await authentication.restoreCallCount()
        let prepareCalls = await identity.prepareCallCount()
        XCTAssertEqual(restoreCalls, 0)
        XCTAssertEqual(prepareCalls, 1)
    }

    @MainActor
    func testWorkspaceStorageCoordinatorFindsAndRestoresManuscriptState() async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(
            named: "작업공간 코디네이터"
        )
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        let volume = try await environment.binderCommands.addNewVolume(
            projectID: project.id
        )
        let coordinator = WorkspaceStorageCoordinator(
            projectID: project.id,
            binderRepository: environment.binderRepository,
            documentRepository: environment.documentRepository,
            workspaceStateRepository: environment.workspaceStateRepository
        )
        let cursor = TextCursorState(location: 12, selectionLength: 2)
        let saved = EditorWorkspaceState(
            projectID: project.id,
            left: EditorPaneState(
                documentID: volume.firstChapterID,
                cursor: cursor
            ),
            right: nil,
            activePane: .left
        )

        try await coordinator.saveWorkspaceState(saved)
        let nodes = try await coordinator.manuscriptTextNodes()
        let restoration = try await coordinator.restoration()
        let lastChapterNumber = try await coordinator.lastManuscriptChapterNumber()

        XCTAssertEqual(nodes.count, 25)
        XCTAssertEqual(nodes.first?.id, volume.firstChapterID)
        XCTAssertEqual(lastChapterNumber, 25)
        XCTAssertEqual(restoration.savedState, saved)
        XCTAssertEqual(restoration.resolvedState, saved)

        let otherProjectState = EditorWorkspaceState(
            projectID: ProjectID(rawValue: UUID()),
            left: EditorPaneState(documentID: nil, cursor: .start),
            right: nil,
            activePane: .left
        )
        do {
            try await coordinator.saveWorkspaceState(otherProjectState)
            XCTFail("다른 작품의 작업공간 상태는 저장하지 않아야 합니다.")
        } catch {
            XCTAssertEqual(
                error as? WorkspaceStorageCoordinatorError,
                .projectMismatch
            )
        }
    }

    @MainActor
    func testProjectListModelRespectsLastProjectLaunchPreference() async throws {
        let environment = try AppEnvironment.testing()
        let first = try await environment.projectManager.createProject(named: "첫 작품")
        _ = try await environment.projectManager.createProject(named: "둘째 작품")
        try await environment.projectManager.selectProject(id: first.id)

        let restoringModel = ProjectListModel(
            projectManager: environment.projectManager,
            projectImporter: environment.projectImporter
        )
        await restoringModel.load(opensLastProject: true)
        XCTAssertEqual(restoringModel.selectedProjectID, first.id)

        let libraryModel = ProjectListModel(
            projectManager: environment.projectManager,
            projectImporter: environment.projectImporter
        )
        await libraryModel.load(opensLastProject: false)
        XCTAssertNil(libraryModel.selectedProjectID)
    }

    @MainActor
    func testProjectListModelRestoresWriterPadBackupThroughProductManager() async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(
            named: "제품 복원 진입점"
        )
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WriterPad-ModelRestore-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: package) }
        _ = try await environment.projectBackupCoordinator.createBackup(
            for: project.id,
            at: package
        )

        let pending = try await environment.projectManager.prepareDeletion(id: project.id)
        try await environment.projectManager.confirmDeletion(pending)
        let deleted = try await environment.projectManager.prepareMoveToDeletedList(
            id: project.id
        )
        _ = try await environment.projectManager.moveToDeletedList(deleted)
        let permanent = try await environment.projectManager.preparePermanentDeletion(
            id: project.id
        )
        _ = try await environment.projectManager.permanentlyDelete(permanent)

        let model = ProjectListModel(
            projectManager: environment.projectManager,
            projectImporter: environment.projectImporter
        )
        await model.restoreBackup(at: package)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.selectedProjectID, project.id)
        XCTAssertEqual(model.selectedProject?.name, "제품 복원 진입점")
        XCTAssertEqual(
            model.importSuccessMessage,
            "‘제품 복원 진입점’ WriterPad 백업을 복원했습니다."
        )
    }

    @MainActor
    func testProjectListModelWaitsForBindingBeforeOpeningNewWorkspace()
        async throws {
        let previous = GlobalSyncPreference.isEnabled()
        GlobalSyncPreference.setEnabled(true)
        defer { GlobalSyncPreference.setEnabled(previous) }
        let environment = try AppEnvironment.testing()
        let binding = DelayedNewProjectBindingService()
        let model = ProjectListModel(
            projectManager: environment.projectManager,
            projectImporter: environment.projectImporter,
            authenticationService: AlwaysAuthenticatedService(),
            projectBindingService: binding
        )
        await model.load(opensLastProject: false)

        let creation = Task { @MainActor in
            await model.create(named: "binding 대기 작품")
        }
        await binding.waitUntilCreateStarts()

        XCTAssertNil(
            model.selectedProjectID,
            "서버 binding 중에는 작업 화면을 먼저 열면 안 됩니다."
        )
        await binding.releaseCreate()
        await creation.value

        XCTAssertNotNil(model.selectedProjectID)
        XCTAssertEqual(model.selectedProject?.name, "binding 대기 작품")
    }

    @MainActor
    func testProjectListModelReportsNameConflictWithDeletedList() async throws {
        let environment = try AppEnvironment.testing()
        let deleted = try await environment.projectManager.createProject(
            named: "삭제 목록 중복 작품"
        )
        let pending = try await environment.projectManager.prepareDeletion(
            id: deleted.id
        )
        try await environment.projectManager.confirmDeletion(pending)
        let deletedListConfirmation = try await environment.projectManager
            .prepareMoveToDeletedList(id: deleted.id)
        _ = try await environment.projectManager.moveToDeletedList(
            deletedListConfirmation
        )

        let model = ProjectListModel(
            projectManager: environment.projectManager,
            projectImporter: environment.projectImporter
        )
        await model.load(opensLastProject: false)
        await model.create(named: "삭제 목록 중복 작품")

        XCTAssertEqual(
            model.errorMessage,
            "삭제 목록에 같은 이름의 작품이 존재합니다."
        )
        XCTAssertTrue(model.selectedProjectID == nil)
        XCTAssertEqual(model.libraryProjects.count, 0)
        XCTAssertEqual(model.deletedProjects.count, 1)
    }

    @MainActor
    func testProjectListModelMovesToDeletedListThenPermanentlyDeletes() async throws {
        let environment = try AppEnvironment.testing()
        let doomed = try await environment.projectManager.createProject(named: "삭제할 작품")
        let survivor = try await environment.projectManager.createProject(named: "남길 작품")
        let model = ProjectListModel(
            projectManager: environment.projectManager,
            projectImporter: environment.projectImporter
        )
        await model.load(opensLastProject: false)
        guard let doomedProject = model.projects.first(where: { $0.id == doomed.id }) else {
            return XCTFail("삭제할 작품이 목록에 있어야 합니다.")
        }

        await model.confirmDeletion(of: doomedProject)
        XCTAssertNil(model.selectedProjectID)
        guard let pendingProject = model.projects.first(where: { $0.id == doomed.id }) else {
            return XCTFail("삭제 대기 작품이 목록에 있어야 합니다.")
        }
        await model.moveToDeletedList(pendingProject)
        let preservedMetadata = try await environment.projectRepository.project(id: doomed.id)
        let restoredProject = try await environment.projectManager.restoreLastProject()

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.libraryProjects.map(\.id), [survivor.id])
        XCTAssertEqual(model.deletedProjects.map(\.id), [doomed.id])
        XCTAssertNil(model.selectedProjectID)
        XCTAssertEqual(restoredProject?.id, survivor.id)
        XCTAssertNotNil(preservedMetadata)

        guard let deletedProject = model.deletedProjects.first else {
            return XCTFail("삭제 목록에 작품이 있어야 합니다.")
        }
        await model.permanentlyDelete(deletedProject)
        let deletedMetadata = try await environment.projectRepository.project(id: doomed.id)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.libraryProjects.map(\.id), [survivor.id])
        XCTAssertTrue(model.deletedProjects.isEmpty)
        XCTAssertNil(model.selectedProjectID)
        XCTAssertNil(deletedMetadata)
    }

    @MainActor
    func testProjectListRenameStaysInLibraryAndPreservesNameOnCollision()
        async throws {
        let environment = try AppEnvironment.testing()
        let first = try await environment.projectManager.createProject(
            named: "이름 변경 전"
        )
        let second = try await environment.projectManager.createProject(
            named: "이미 있는 작품"
        )
        let model = ProjectListModel(
            projectManager: environment.projectManager,
            projectImporter: environment.projectImporter
        )
        await model.load(opensLastProject: false)
        let firstRow = try XCTUnwrap(
            model.libraryProjects.first { $0.id == first.id }
        )

        await model.rename(firstRow, to: "이름 변경 후")

        XCTAssertNil(model.selectedProjectID)
        XCTAssertEqual(
            model.libraryProjects.first { $0.id == first.id }?.name,
            "이름 변경 후"
        )
        let renamedRow = try XCTUnwrap(
            model.libraryProjects.first { $0.id == first.id }
        )
        await model.rename(renamedRow, to: second.name)

        XCTAssertNil(model.selectedProjectID)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(
            model.libraryProjects.first { $0.id == first.id }?.name,
            "이름 변경 후"
        )
    }

    @MainActor
    func testTestingEnvironmentUsesWritableInMemoryMetadata() async throws {
        let environment = try AppEnvironment.testing()
        let project = Project(
            id: ProjectID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
            ),
            name: "환경 테스트",
            createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 0)
        )

        try await environment.projectRepository.save(project)
        let projects = try await environment.projectRepository.projects()

        XCTAssertEqual(projects, [project])
    }

    func testNoOpFutureNotifierAcceptsLocalEvents() async {
        await NoOpFutureChangeNotifier().record(.appLaunched)
    }

    @MainActor
    func testAddNewVolumeUsesCurrentManuscriptIdentityWhenTappedNodeIsStale()
        async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(
            named: "새 권 오래된 UUID"
        )
        let model = BinderViewModel(
            repository: environment.binderRepository,
            commands: environment.binderCommands
        )
        await model.load(projectID: project.id)
        let currentManuscript = try XCTUnwrap(
            model.roots.first { $0.fixedCategory == .manuscript }
        )
        let staleManuscript = BinderNode(
            id: DocumentID(rawValue: UUID()),
            projectID: currentManuscript.projectID,
            kind: currentManuscript.kind,
            relativePath: currentManuscript.relativePath,
            displayName: currentManuscript.displayName,
            fixedCategory: currentManuscript.fixedCategory,
            userOrder: currentManuscript.userOrder,
            contentState: currentManuscript.contentState,
            isExpanded: currentManuscript.isExpanded
        )

        let firstChapter = await model.addNewVolume(in: staleManuscript)

        XCTAssertNotNil(firstChapter)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(firstChapter?.relativePath.rawValue, "메인/원고/1권/001화.txt")
        let documents = try await environment.documentRepository.documents(
            in: project.id
        )
        let volumeDocuments = documents.filter {
            $0.relativePath.rawValue.hasPrefix("메인/원고/1권")
        }
        XCTAssertEqual(volumeDocuments.count, 26)
        let refreshedRoots = try await environment.binderRepository.rootNodes(
            in: project.id
        )
        XCTAssertTrue(
            refreshedRoots.first { $0.fixedCategory == .manuscript }?
                .isExpanded == true
        )
    }

    func testEditorExternalTrackerDistinguishesDocumentVersionAndComposition() {
        let firstID = DocumentID(rawValue: UUID())
        let secondID = DocumentID(rawValue: UUID())
        var tracker = EditorExternalUpdateTracker()

        XCTAssertEqual(
            tracker.decision(
                for: EditorExternalSnapshot(documentID: firstID, version: 1),
                isComposing: false
            ),
            .applyDocument
        )
        XCTAssertEqual(
            tracker.decision(
                for: EditorExternalSnapshot(documentID: firstID, version: 1),
                isComposing: false
            ),
            .none
        )
        XCTAssertEqual(
            tracker.decision(
                for: EditorExternalSnapshot(documentID: firstID, version: 2),
                isComposing: false
            ),
            .applyVersion
        )
        XCTAssertEqual(
            tracker.decision(
                for: EditorExternalSnapshot(documentID: secondID, version: 1),
                isComposing: true
            ),
            .deferForComposition
        )
        XCTAssertEqual(
            tracker.decision(
                for: EditorExternalSnapshot(documentID: secondID, version: 1),
                isComposing: false
            ),
            .applyDocument
        )
    }

    func testFocusStateMachineRestoresOnlyPreviouslyFocusedEditor() {
        var focused = EditorFocusStateMachine()
        XCTAssertEqual(focused.handle(.focusGained), [])
        XCTAssertEqual(focused.handle(.compositionStarted), [])
        XCTAssertEqual(focused.phase, .composing)
        XCTAssertEqual(focused.handle(.sceneBecameInactive), [])
        XCTAssertEqual(focused.handle(.focusLost), [])
        XCTAssertEqual(focused.phase, .backgrounded)
        XCTAssertEqual(
            focused.handle(.sceneBecameActive(hasDocument: true)),
            [.requestFocus]
        )
        XCTAssertEqual(focused.phase, .restoring)

        var idle = EditorFocusStateMachine()
        XCTAssertEqual(idle.handle(.sceneBecameInactive), [])
        XCTAssertEqual(idle.handle(.sceneBecameActive(hasDocument: true)), [])
        XCTAssertEqual(idle.phase, .idle)
    }

    func testDualEditorRouterAllowsSameDocumentInBothPanes() {
        let leftID = DocumentID(rawValue: UUID())
        let rightID = DocumentID(rawValue: UUID())
        let newID = DocumentID(rawValue: UUID())

        XCTAssertEqual(
            DualEditorRouter.route(
                selectedDocumentID: leftID,
                isSplitEnabled: true,
                activePane: .right,
                leftDocumentID: leftID,
                rightDocumentID: rightID
            ),
            .openIn(.right)
        )
        XCTAssertEqual(
            DualEditorRouter.route(
                selectedDocumentID: rightID,
                isSplitEnabled: true,
                activePane: .left,
                leftDocumentID: leftID,
                rightDocumentID: rightID
            ),
            .openIn(.left)
        )
        XCTAssertEqual(
            DualEditorRouter.route(
                selectedDocumentID: newID,
                isSplitEnabled: true,
                activePane: .right,
                leftDocumentID: leftID,
                rightDocumentID: rightID
            ),
            .openIn(.right)
        )
        XCTAssertEqual(
            DualEditorRouter.route(
                selectedDocumentID: leftID,
                isSplitEnabled: false,
                activePane: .right,
                leftDocumentID: leftID,
                rightDocumentID: leftID
            ),
            .openIn(.right)
        )
    }

    func testPortraitDeviceKeepsDualEditorCompactAcrossWindowResize() {
        let windowSizes = [
            (width: 834.0, height: 1194.0),
            (width: 1024.0, height: 700.0),
            (width: 620.0, height: 500.0),
            (width: 1180.0, height: 760.0),
        ]

        for size in windowSizes {
            XCTAssertTrue(
                DualEditorLayoutPolicy.usesCompactLayout(
                    width: size.width,
                    height: size.height,
                    screenOrientation: .portrait
                )
            )
        }
    }

    func testHiddenSplitPaneIsExcludedFromSyncEditingGuards() {
        let leftID = DocumentID(rawValue: UUID())
        let hiddenRightID = DocumentID(rawValue: UUID())
        let left = SyncEditingPaneState(
            documentID: leftID,
            isDirty: false,
            isComposing: false
        )
        let right = SyncEditingPaneState(
            documentID: hiddenRightID,
            isDirty: false,
            isComposing: false
        )

        let singlePane = SyncEditingGuardCollector.collect(
            left: left,
            right: right,
            showsSplit: false,
            activePaneIsLeft: true
        )
        XCTAssertEqual(Set(singlePane.keys), [leftID.rawValue])

        let visibleSplit = SyncEditingGuardCollector.collect(
            left: left,
            right: right,
            showsSplit: true,
            activePaneIsLeft: true
        )
        XCTAssertEqual(
            Set(visibleSplit.keys),
            [leftID.rawValue, hiddenRightID.rawValue]
        )
    }

    func testLandscapeDevicePresentsSplitOnlyAtSufficientWidth() {
        XCTAssertFalse(
            DualEditorLayoutPolicy.usesCompactLayout(
                width: 1194,
                height: 834,
                screenOrientation: .landscape
            )
        )
        XCTAssertTrue(
            DualEditorLayoutPolicy.usesCompactLayout(
                width: 500,
                height: 834,
                screenOrientation: .landscape
            )
        )
    }

    func testSharedEditorTextChangeMovesOtherPaneCursorByUTF16Delta() {
        let original = "초반🙂\n후반 문장"
        let cursor = TextCursorState(
            location: UInt(("초반🙂\n후반" as NSString).length),
            selectionLength: 0
        )
        let inserted = "초반에 추가🙂\n후반 문장"

        let adjusted = SharedEditorTextChange.adjustedCursor(
            cursor,
            from: original,
            to: inserted
        )

        XCTAssertEqual(
            adjusted.location,
            UInt(("초반에 추가🙂\n후반" as NSString).length)
        )
        XCTAssertEqual(adjusted.selectionLength, 0)
    }

    func testSharedEditorMutationMovesOtherPaneCursorWithoutScanningWholeText() {
        let cursor = TextCursorState(location: 12, selectionLength: 3)
        let mutation = SharedEditorTextChange.Mutation(
            range: TextCursorState(location: 4, selectionLength: 2),
            replacementText: "한🙂"
        )

        let adjusted = SharedEditorTextChange.adjustedCursor(
            cursor,
            applying: mutation
        )

        XCTAssertEqual(adjusted.location, 13)
        XCTAssertEqual(adjusted.selectionLength, 3)
    }

    @MainActor
    func testSharedEditorAppliesContinuousMutationWithoutFullTextAssignment() {
        let documentID = DocumentID(rawValue: UUID())
        let original = String(repeating: "긴 원고 문장🙂\n", count: 2_000)
        let mutation = SharedEditorTextChange.Mutation(
            range: TextCursorState(location: 2, selectionLength: 0),
            replacementText: "추가🙂"
        )
        let updated = (original as NSString).replacingCharacters(
            in: NSRange(location: 2, length: 0),
            with: mutation.replacementText
        )
        var text = original
        var selection = TextCursorState.start
        let initialEditor = iPadTextEditor(
            text: Binding(get: { text }, set: { text = $0 }),
            documentID: documentID,
            externalVersion: 0,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusRequest: 0,
            isActive: false
        )
        let coordinator = initialEditor.makeCoordinator()
        let textView = SmartTextView()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)
        let fullAssignmentCount = textView.fullTextAssignmentCount

        text = updated
        coordinator.parent = iPadTextEditor(
            text: Binding(get: { text }, set: { text = $0 }),
            documentID: documentID,
            externalVersion: 1,
            externalTextMutation: SharedEditorTextChange.VersionedMutation(
                baseVersion: 0,
                version: 1,
                mutation: mutation
            ),
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusRequest: 0,
            isActive: false
        )
        coordinator.applyExternalState(to: textView)

        XCTAssertEqual(textView.text, updated)
        XCTAssertEqual(textView.fullTextAssignmentCount, fullAssignmentCount)
    }

    @MainActor
    func testSharedEditorRejectsIMEIntermediateMutationAndRestoresConfirmedText() {
        let documentID = DocumentID(rawValue: UUID())
        var text = "캬"
        var selection = TextCursorState.start
        let initialEditor = iPadTextEditor(
            text: Binding(get: { text }, set: { text = $0 }),
            documentID: documentID,
            externalVersion: 0,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusRequest: 0,
            isActive: false
        )
        let coordinator = initialEditor.makeCoordinator()
        let textView = SmartTextView()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)
        let fullAssignmentCount = textView.fullTextAssignmentCount

        text = "캬캬"
        coordinator.parent = iPadTextEditor(
            text: Binding(get: { text }, set: { text = $0 }),
            documentID: documentID,
            externalVersion: 1,
            externalTextMutation: SharedEditorTextChange.VersionedMutation(
                baseVersion: 0,
                version: 1,
                mutation: SharedEditorTextChange.Mutation(
                    range: TextCursorState(location: 1, selectionLength: 0),
                    replacementText: "ㅋㅑ"
                )
            ),
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusRequest: 0,
            isActive: false
        )
        coordinator.applyExternalState(to: textView)

        XCTAssertEqual(textView.text, "캬캬")
        XCTAssertEqual(textView.fullTextAssignmentCount, fullAssignmentCount + 1)
    }

    @MainActor
    func testZeroLengthMarkedRangeDoesNotBlockDocumentChange() {
        final class ZeroLengthMarkedTextView: SmartTextView {
            var exposesZeroLengthMarkedRange = false

            override var markedTextRange: UITextRange? {
                guard exposesZeroLengthMarkedRange,
                      let position = selectedTextRange?.end
                else { return super.markedTextRange }
                return textRange(from: position, to: position)
            }
        }

        let firstDocumentID = DocumentID(rawValue: UUID())
        let secondDocumentID = DocumentID(rawValue: UUID())
        var text = "내용이 있는 기존 문서"
        var selection = TextCursorState(
            location: UInt(text.utf16.count),
            selectionLength: 0
        )
        var compositionStates: [Bool] = []

        func editor(
            documentID: DocumentID,
            version: UInt64
        ) -> iPadTextEditor {
            iPadTextEditor(
                text: Binding(get: { text }, set: { text = $0 }),
                documentID: documentID,
                externalVersion: version,
                selection: Binding(
                    get: { selection },
                    set: { selection = $0 }
                ),
                focusRequest: 0,
                onCompositionStateChange: {
                    _, isComposing in
                    compositionStates.append(isComposing)
                }
            )
        }

        let coordinator = editor(
            documentID: firstDocumentID,
            version: 0
        ).makeCoordinator()
        let textView = ZeroLengthMarkedTextView()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)

        textView.exposesZeroLengthMarkedRange = true
        coordinator.textViewDidChangeSelection(textView)
        XCTAssertNotNil(textView.markedTextRange)
        XCTAssertEqual(
            textView.offset(
                from: textView.markedTextRange!.start,
                to: textView.markedTextRange!.end
            ),
            0
        )
        XCTAssertTrue(compositionStates.isEmpty)

        text = "다음 문서 본문"
        selection = .start
        coordinator.parent = editor(
            documentID: secondDocumentID,
            version: 0
        )
        coordinator.applyExternalState(to: textView)

        XCTAssertEqual(textView.text, "다음 문서 본문")
        XCTAssertTrue(compositionStates.isEmpty)
    }

    @MainActor
    func testCompositionStateEndsWhenMarkedRangeShrinksToZero() {
        final class ShrinkingMarkedTextView: SmartTextView {
            var exposesZeroLengthMarkedRange = false

            override var markedTextRange: UITextRange? {
                guard exposesZeroLengthMarkedRange,
                      let position = selectedTextRange?.end
                else { return super.markedTextRange }
                return textRange(from: position, to: position)
            }
        }

        let documentID = DocumentID(rawValue: UUID())
        var text = "내용이 있는 문서 "
        var selection = TextCursorState(
            location: UInt(text.utf16.count),
            selectionLength: 0
        )
        var compositionStates: [Bool] = []
        let editor = iPadTextEditor(
            text: Binding(get: { text }, set: { text = $0 }),
            documentID: documentID,
            externalVersion: 0,
            selection: Binding(
                get: { selection },
                set: { selection = $0 }
            ),
            focusRequest: 0,
            onCompositionStateChange: {
                _, isComposing in
                compositionStates.append(isComposing)
            }
        )
        let coordinator = editor.makeCoordinator()
        let textView = ShrinkingMarkedTextView()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)

        textView.setMarkedText(
            "한",
            selectedRange: NSRange(location: 1, length: 0)
        )
        coordinator.textViewDidChange(textView)
        XCTAssertEqual(compositionStates, [true])

        textView.exposesZeroLengthMarkedRange = true
        coordinator.textViewDidChangeSelection(textView)

        XCTAssertEqual(compositionStates, [true, false])
    }

    @MainActor
    func testCompositionCommitRequestUnmarksTextAndReportsCompletion() async {
        let documentID = DocumentID(rawValue: UUID())
        var text = String(repeating: "ㅇ\n", count: 2_000)
        var selection = TextCursorState(
            location: UInt(text.utf16.count),
            selectionLength: 0
        )
        var compositionStates: [Bool] = []

        func editor(commitRequest: UInt64) -> iPadTextEditor {
            iPadTextEditor(
                text: Binding(get: { text }, set: { text = $0 }),
                documentID: documentID,
                externalVersion: 0,
                selection: Binding(get: { selection }, set: { selection = $0 }),
                focusRequest: 0,
                compositionCommitRequest: commitRequest,
                onCompositionStateChange: {
                    _, isComposing in
                    compositionStates.append(isComposing)
                }
            )
        }

        let coordinator = editor(commitRequest: 0).makeCoordinator()
        let textView = SmartTextView()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)
        textView.setMarkedText("네목", selectedRange: NSRange(location: 2, length: 0))
        coordinator.textViewDidChange(textView)
        XCTAssertNotNil(textView.markedTextRange)
        XCTAssertEqual(compositionStates.last, true)

        coordinator.parent = editor(commitRequest: 1)
        coordinator.applyExternalState(to: textView)
        let committed = expectation(description: "바인더 전환 전 조합 확정")
        DispatchQueue.main.async {
            DispatchQueue.main.async { committed.fulfill() }
        }
        await fulfillment(of: [committed], timeout: 1)

        XCTAssertNil(textView.markedTextRange)
        XCTAssertTrue(textView.text.hasSuffix("네목"))
        XCTAssertEqual(compositionStates.last, false)
    }

    @MainActor
    func testCompositionCommitRequestRetriesWhenKoreanIMEIgnoresInitialCommits() async {
        final class DelayedCompositionCommitTextView: SmartTextView {
            var ignoredCommitCount = 1
            private(set) var commitAttemptCount = 0

            override func unmarkText() {
                commitAttemptCount += 1
                guard ignoredCommitCount == 0 else {
                    ignoredCommitCount -= 1
                    return
                }
                super.unmarkText()
            }
        }

        let documentID = DocumentID(rawValue: UUID())
        var text = "전환 직전 입력 "
        var selection = TextCursorState(
            location: UInt(text.utf16.count),
            selectionLength: 0
        )
        var compositionStates: [Bool] = []

        func editor(commitRequest: UInt64) -> iPadTextEditor {
            iPadTextEditor(
                text: Binding(get: { text }, set: { text = $0 }),
                documentID: documentID,
                externalVersion: 0,
                selection: Binding(get: { selection }, set: { selection = $0 }),
                focusRequest: 0,
                compositionCommitRequest: commitRequest,
                onCompositionStateChange: {
                    _, isComposing in
                    compositionStates.append(isComposing)
                }
            )
        }

        let coordinator = editor(commitRequest: 0).makeCoordinator()
        let textView = DelayedCompositionCommitTextView()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)
        textView.setMarkedText("한글", selectedRange: NSRange(location: 2, length: 0))
        coordinator.textViewDidChange(textView)
        XCTAssertNotNil(textView.markedTextRange)
        XCTAssertEqual(compositionStates.last, true)

        coordinator.parent = editor(commitRequest: 1)
        coordinator.applyExternalState(to: textView)
        let committed = expectation(description: "무시된 한글 조합 확정 재시도")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) {
            committed.fulfill()
        }
        await fulfillment(of: [committed], timeout: 1)

        XCTAssertGreaterThanOrEqual(textView.commitAttemptCount, 2)
        XCTAssertNil(textView.markedTextRange)
        XCTAssertTrue(textView.text.hasSuffix("한글"))
        XCTAssertEqual(compositionStates.last, false)
    }

    @MainActor
    func testCompositionCommitRequestRetriesPersistentlyDelayedMarkedText()
        async {
        final class DelayedCompositionTextView: SmartTextView {
            private(set) var commitAttemptCount = 0
            var ignoredCommitCount = 12

            override func unmarkText() {
                commitAttemptCount += 1
                guard ignoredCommitCount == 0 else {
                    ignoredCommitCount -= 1
                    return
                }
                super.unmarkText()
            }
        }

        let documentID = DocumentID(rawValue: UUID())
        var text = "전환 직전 "
        var selection = TextCursorState(
            location: UInt(text.utf16.count),
            selectionLength: 0
        )
        var compositionStates: [Bool] = []

        func editor(commitRequest: UInt64) -> iPadTextEditor {
            iPadTextEditor(
                text: Binding(get: { text }, set: { text = $0 }),
                documentID: documentID,
                externalVersion: 0,
                selection: Binding(
                    get: { selection },
                    set: { selection = $0 }
                ),
                focusRequest: 0,
                compositionCommitRequest: commitRequest,
                onTextChange: { sourceDocumentID, snapshot, _ in
                    guard sourceDocumentID == documentID,
                          let snapshot
                    else { return }
                    text = snapshot
                },
                onCompositionStateChange: {
                    _, isComposing in
                    compositionStates.append(isComposing)
                }
            )
        }

        let coordinator = editor(commitRequest: 0).makeCoordinator()
        let textView = DelayedCompositionTextView()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)
        textView.setMarkedText(
            "한글",
            selectedRange: NSRange(location: 2, length: 0)
        )
        coordinator.textViewDidChange(textView)
        XCTAssertNotNil(textView.markedTextRange)

        coordinator.parent = editor(commitRequest: 1)
        coordinator.applyExternalState(to: textView)
        let committed = expectation(
            description: "오래 지연된 marked text 안전 해제"
        )
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(500)
        ) {
            committed.fulfill()
        }
        await fulfillment(of: [committed], timeout: 1)

        XCTAssertGreaterThanOrEqual(textView.commitAttemptCount, 13)
        XCTAssertNil(textView.markedTextRange)
        XCTAssertTrue(textView.text.hasSuffix("한글"))
        XCTAssertEqual(text, textView.text)
        XCTAssertEqual(compositionStates.last, false)
    }

    @MainActor
    func testExplicitCompositionCommitReacknowledgesAlreadyUnmarkedIMEState() async {
        let documentID = DocumentID(rawValue: UUID())
        var text = "조합 완료 신호 순서"
        var selection = TextCursorState(
            location: UInt(text.utf16.count),
            selectionLength: 0
        )
        var compositionStates: [Bool] = []

        func editor(commitRequest: UInt64) -> iPadTextEditor {
            iPadTextEditor(
                text: Binding(get: { text }, set: { text = $0 }),
                documentID: documentID,
                externalVersion: 0,
                selection: Binding(get: { selection }, set: { selection = $0 }),
                focusRequest: 0,
                compositionCommitRequest: commitRequest,
                onCompositionStateChange: {
                    _, isComposing in
                    compositionStates.append(isComposing)
                }
            )
        }

        let coordinator = editor(commitRequest: 0).makeCoordinator()
        let textView = SmartTextView()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)
        textView.setMarkedText("확정", selectedRange: NSRange(location: 2, length: 0))
        coordinator.textViewDidChange(textView)
        textView.unmarkText()
        coordinator.textViewDidChangeSelection(textView)
        XCTAssertEqual(compositionStates, [true, false])

        // false 완료 Task보다 앞선 true Task가 나중에 모델을 덮었다고 가정한다.
        // 브리지는 이미 false라고 기억하더라도 명시적 커밋에는 다시 응답해야 한다.
        compositionStates.removeAll()
        coordinator.parent = editor(commitRequest: 1)
        coordinator.applyExternalState(to: textView)
        let acknowledged = expectation(description: "현재 조합 완료 상태 재확인")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) {
            acknowledged.fulfill()
        }
        await fulfillment(of: [acknowledged], timeout: 1)

        XCTAssertEqual(compositionStates, [false])
        XCTAssertNil(textView.markedTextRange)
    }

    @MainActor
    func testCompositionStateRecordingCannotBeReversedByAsyncCompletion()
        async throws {
        let environment = try AppEnvironment.testing()
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            workspaceStateRepository:
                environment.workspaceStateRepository
        )

        let composingGeneration = try XCTUnwrap(
            model.recordCompositionState(true)
        )
        let completedGeneration = try XCTUnwrap(
            model.recordCompositionState(false)
        )

        XCTAssertFalse(model.isComposing)
        let staleCompletionWasApplied =
            await model.finishCompositionStateUpdate(
                true,
                generation: composingGeneration
            )
        XCTAssertFalse(staleCompletionWasApplied)
        let latestCompletionWasApplied =
            await model.finishCompositionStateUpdate(
                false,
                generation: completedGeneration
            )
        XCTAssertTrue(latestCompletionWasApplied)
        XCTAssertFalse(model.isComposing)
    }

    @MainActor
    func testCompositionCallbackKeepsDisplayedDocumentIdentity() {
        let displayedDocumentID = DocumentID(rawValue: UUID())
        let incomingDocumentID = DocumentID(rawValue: UUID())
        var text = ""
        var selection = TextCursorState.start
        var updates: [(DocumentID, Bool)] = []
        func editor(documentID: DocumentID) -> iPadTextEditor {
            iPadTextEditor(
                text: Binding(get: { text }, set: { text = $0 }),
                documentID: documentID,
                externalVersion: 0,
                selection: Binding(
                    get: { selection },
                    set: { selection = $0 }
                ),
                focusRequest: 0,
                onCompositionStateChange: {
                    updates.append(($0, $1))
                }
            )
        }
        let coordinator = editor(
            documentID: displayedDocumentID
        ).makeCoordinator()
        let textView = SmartTextView()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)
        textView.setMarkedText(
            "한글",
            selectedRange: NSRange(location: 2, length: 0)
        )
        coordinator.textViewDidChange(textView)

        coordinator.parent = editor(documentID: incomingDocumentID)
        textView.unmarkText()
        coordinator.textViewDidChangeSelection(textView)

        XCTAssertEqual(updates.map(\.0), [
            displayedDocumentID,
            displayedDocumentID,
        ])
        XCTAssertEqual(updates.map(\.1), [true, false])
    }

    @MainActor
    func testSharedEditorAppliesSelectionDeletionToOtherPane() {
        let documentID = DocumentID(rawValue: UUID())
        var text = "문장 중간 선택 삭제"
        var selection = TextCursorState.start
        let initialEditor = iPadTextEditor(
            text: Binding(get: { text }, set: { text = $0 }),
            documentID: documentID,
            externalVersion: 0,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusRequest: 0,
            isActive: false
        )
        let coordinator = initialEditor.makeCoordinator()
        let textView = SmartTextView()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)
        let fullAssignmentCount = textView.fullTextAssignmentCount

        let deletionRange = TextCursorState(location: 3, selectionLength: 3)
        text = (text as NSString).replacingCharacters(
            in: NSRange(location: 3, length: 3),
            with: ""
        )
        coordinator.parent = iPadTextEditor(
            text: Binding(get: { text }, set: { text = $0 }),
            documentID: documentID,
            externalVersion: 1,
            externalTextMutation: SharedEditorTextChange.VersionedMutation(
                baseVersion: 0,
                version: 1,
                mutation: SharedEditorTextChange.Mutation(
                    range: deletionRange,
                    replacementText: ""
                )
            ),
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusRequest: 0,
            isActive: false
        )
        coordinator.applyExternalState(to: textView)

        XCTAssertEqual(textView.text, text)
        XCTAssertEqual(textView.fullTextAssignmentCount, fullAssignmentCount)
    }

    @MainActor
    func testSharedEditorFallsBackToFullTextWhenMutationVersionSkips() {
        let documentID = DocumentID(rawValue: UUID())
        var text = "기준 원고"
        var selection = TextCursorState.start
        let initialEditor = iPadTextEditor(
            text: Binding(get: { text }, set: { text = $0 }),
            documentID: documentID,
            externalVersion: 0,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusRequest: 0,
            isActive: false
        )
        let coordinator = initialEditor.makeCoordinator()
        let textView = SmartTextView()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)
        let fullAssignmentCount = textView.fullTextAssignmentCount

        text = "중간 갱신을 건너뛴 최신 원고🙂"
        coordinator.parent = iPadTextEditor(
            text: Binding(get: { text }, set: { text = $0 }),
            documentID: documentID,
            externalVersion: 2,
            externalTextMutation: SharedEditorTextChange.VersionedMutation(
                baseVersion: 1,
                version: 2,
                mutation: SharedEditorTextChange.Mutation(
                    range: .start,
                    replacementText: "무시할 증분"
                )
            ),
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusRequest: 0,
            isActive: false
        )
        coordinator.applyExternalState(to: textView)

        XCTAssertEqual(textView.text, text)
        XCTAssertEqual(textView.fullTextAssignmentCount, fullAssignmentCount + 1)
    }

    @MainActor
    func testNativeEditorReportsExactMutationForSharedPaneSync() throws {
        var text = "가나다"
        var selection = TextCursorState(location: 1, selectionLength: 1)
        var reportedMutation: SharedEditorTextChange.Mutation?
        let editor = iPadTextEditor(
            text: Binding(get: { text }, set: { text = $0 }),
            documentID: DocumentID(rawValue: UUID()),
            externalVersion: 0,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusRequest: 0,
            textRuleSettings: .disabled,
            onTextChange: { _, _, mutation in reportedMutation = mutation }
        )
        let coordinator = editor.makeCoordinator()
        let textView = SmartTextView()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)
        let range = NSRange(location: 1, length: 1)

        XCTAssertTrue(
            coordinator.textView(
                textView,
                shouldChangeTextIn: range,
                replacementText: "한🙂"
            )
        )
        textView.textStorage.replaceCharacters(in: range, with: "한🙂")
        coordinator.textViewDidChange(textView)

        let mutation = try XCTUnwrap(reportedMutation)
        XCTAssertEqual(mutation.range, TextCursorState(location: 1, selectionLength: 1))
        XCTAssertEqual(mutation.replacementText, "한🙂")
        XCTAssertEqual(text, "가나다", "정상 입력은 전체 SwiftUI String을 게시하지 않는다")
        XCTAssertEqual(textView.text, "가한🙂다")
    }

    @MainActor
    func testNativeEditorAttributesDelayedCallbackToDisplayedDocument()
        throws {
        let displayedDocumentID = DocumentID(rawValue: UUID())
        let incomingDocumentID = DocumentID(rawValue: UUID())
        var displayedText = "6화 원문"
        var incomingText = "7화 원문"
        var selection = TextCursorState(
            location: UInt(displayedText.utf16.count),
            selectionLength: 0
        )
        var reportedDocumentID: DocumentID?
        var reportedRecoverySnapshot: String?
        let displayedEditor = iPadTextEditor(
            text: Binding(
                get: { displayedText },
                set: { displayedText = $0 }
            ),
            documentID: displayedDocumentID,
            externalVersion: 0,
            selection: Binding(
                get: { selection },
                set: { selection = $0 }
            ),
            focusRequest: 0,
            textRuleSettings: .disabled
        )
        let coordinator = displayedEditor.makeCoordinator()
        let textView = SmartTextView()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)

        // SwiftUI 모델은 다음 문서로 이동했지만 기존 UITextView가 한글 조합
        // callback을 늦게 전달하는 전환 경계를 재현한다.
        coordinator.parent = iPadTextEditor(
            text: Binding(
                get: { incomingText },
                set: { incomingText = $0 }
            ),
            documentID: incomingDocumentID,
            externalVersion: 1,
            selection: Binding(
                get: { selection },
                set: { selection = $0 }
            ),
            focusRequest: 0,
            textRuleSettings: .disabled,
            onTextChange: { sourceDocumentID, snapshot, _ in
                reportedDocumentID = sourceDocumentID
                reportedRecoverySnapshot = snapshot
            }
        )
        var insertionRange = NSRange(
            location: textView.textStorage.length,
            length: 0
        )
        // 두 번의 text-storage 변경을 한 callback으로 합쳐 IME의 전체
        // 복구 스냅샷 경로도 함께 통과시킨다.
        textView.textStorage.replaceCharacters(
            in: insertionRange,
            with: "아"
        )
        insertionRange.location = textView.textStorage.length
        textView.textStorage.replaceCharacters(
            in: insertionRange,
            with: "아"
        )
        coordinator.textViewDidChange(textView)

        XCTAssertEqual(reportedDocumentID, displayedDocumentID)
        XCTAssertNotEqual(reportedDocumentID, incomingDocumentID)
        XCTAssertEqual(reportedRecoverySnapshot, "6화 원문아아")
        XCTAssertEqual(incomingText, "7화 원문")
    }

    @MainActor
    func testNativeEditorDoesNotCreateFullSnapshotForOrdinaryInput() throws {
        let original = String(repeating: "긴 원고🙂\n", count: 50_000)
        var boundText = original
        var selection = TextCursorState(
            location: UInt(original.utf16.count),
            selectionLength: 0
        )
        var recoverySnapshotWasReported = false
        var reportedMutation: SharedEditorTextChange.Mutation?
        let editor = iPadTextEditor(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            documentID: DocumentID(rawValue: UUID()),
            externalVersion: 0,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusRequest: 0,
            textRuleSettings: .disabled,
            onTextChange: { _, snapshot, mutation in
                recoverySnapshotWasReported = snapshot != nil
                reportedMutation = mutation
            }
        )
        let coordinator = editor.makeCoordinator()
        let textView = SmartTextView()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)

        textView.insertText("가")

        XCTAssertFalse(recoverySnapshotWasReported)
        XCTAssertEqual(reportedMutation?.replacementText, "가")
        XCTAssertEqual(boundText, original)
        XCTAssertTrue(textView.text.hasSuffix("가"))
    }

    @MainActor
    func testManuscriptBufferMaintainsUnicodeStatisticsFromLocalMutations() {
        let original = "A\u{301}🙂한글"
        let buffer = ManuscriptTextBuffer(original)
        let initialSnapshotCount = buffer.snapshotCreationCount
        let insertionLocation = UInt(("A\u{301}🙂" as NSString).length)

        XCTAssertTrue(
            buffer.apply(
                SharedEditorTextChange.Mutation(
                    range: TextCursorState(
                        location: insertionLocation,
                        selectionLength: 0
                    ),
                    replacementText: "\u{301}"
                )
            )
        )
        XCTAssertEqual(buffer.snapshotCreationCount, initialSnapshotCount)

        let snapshot = buffer.snapshot()
        XCTAssertEqual(buffer.statistics.characterCount, snapshot.count)
        XCTAssertEqual(buffer.utf16Length, snapshot.utf16.count)
    }

    @MainActor
    func testDualTextViewsKeepIndependentUndoHistories() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let host = UIViewController()
        window.rootViewController = host
        let left = SmartTextView()
        let right = SmartTextView()
        left.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        right.frame = CGRect(x: 400, y: 0, width: 400, height: 600)
        host.view.addSubview(left)
        host.view.addSubview(right)
        window.makeKeyAndVisible()

        XCTAssertTrue(left.becomeFirstResponder())
        left.insertText("왼쪽")
        XCTAssertTrue(right.becomeFirstResponder())
        right.insertText("오른쪽")

        left.performUndo()

        XCTAssertEqual(left.text, "")
        XCTAssertEqual(right.text, "오른쪽")
        XCTAssertTrue(try XCTUnwrap(right.undoManager).canUndo)
    }

    @MainActor
    func testInactiveEditorDefersAndCancelsResponderResignationOutsideViewUpdate() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let host = UIViewController()
        let textView = SmartTextView(frame: window.bounds)
        host.view.addSubview(textView)
        window.rootViewController = host
        window.makeKeyAndVisible()

        let documentID = DocumentID(rawValue: UUID())
        func editor(isActive: Bool) -> iPadTextEditor {
            iPadTextEditor(
                text: .constant("원고"),
                documentID: documentID,
                externalVersion: 1,
                selection: .constant(.start),
                focusRequest: 0,
                isActive: isActive
            )
        }

        let coordinator = editor(isActive: true).makeCoordinator()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)
        XCTAssertTrue(textView.becomeFirstResponder())

        coordinator.parent = editor(isActive: false)
        coordinator.applyExternalState(to: textView)
        XCTAssertTrue(
            textView.isFirstResponder,
            "SwiftUI updateUIView 안에서 동기적으로 responder를 반납하면 포커스 재진입이 발생할 수 있습니다."
        )

        coordinator.parent = editor(isActive: true)
        coordinator.applyExternalState(to: textView)
        let cancellationSettled = expectation(description: "취소된 responder 전환 처리")
        DispatchQueue.main.async { cancellationSettled.fulfill() }
        await fulfillment(of: [cancellationSettled], timeout: 1)
        XCTAssertTrue(textView.isFirstResponder)

        coordinator.parent = editor(isActive: false)
        coordinator.applyExternalState(to: textView)
        let resignationSettled = expectation(description: "비동기 responder 반납 처리")
        DispatchQueue.main.async { resignationSettled.fulfill() }
        await fulfillment(of: [resignationSettled], timeout: 1)
        XCTAssertFalse(textView.isFirstResponder)
    }

    @MainActor
    func testSmartTextViewPreservesKoreanEmojiSelectionAndSkipsSameTextAssignment() {
        let textView = SmartTextView()
        let text = "한글 조합과 이모지 👩‍💻🙂"
        let selection = TextCursorState(location: 3, selectionLength: 4)

        textView.applyExternalText(text, selection: selection, clearsUndoHistory: true)
        let assignmentCount = textView.fullTextAssignmentCount
        textView.applyExternalText(text, selection: selection, clearsUndoHistory: false)

        XCTAssertEqual(textView.text, text)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 3, length: 4))
        XCTAssertEqual(textView.fullTextAssignmentCount, assignmentCount)
    }

    @MainActor
    func testCoordinatorClampsLongDocumentSelectionWithoutReassigningText() {
        let text = String(repeating: "긴 원고🙂\n", count: 10_000)
        var selection = TextCursorState.start
        let editor = iPadTextEditor(
            text: .constant(text),
            documentID: DocumentID(rawValue: UUID()),
            externalVersion: 0,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusRequest: 0,
            isActive: false
        )
        let coordinator = editor.makeCoordinator()
        let textView = SmartTextView()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)
        let assignmentCount = textView.fullTextAssignmentCount

        selection = TextCursorState(location: .max, selectionLength: .max)
        coordinator.applyExternalState(to: textView)

        XCTAssertEqual(
            textView.selectedRange,
            NSRange(location: textView.textStorage.length, length: 0)
        )
        XCTAssertEqual(textView.fullTextAssignmentCount, assignmentCount)
    }

    @MainActor
    func testDirectInputDoesNotForceFullLongDocumentLayout() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        let host = UIViewController()
        window.rootViewController = host
        var text = String(repeating: "긴 원고 문장🙂\n", count: 5_000)
        var selection = TextCursorState(
            location: UInt(text.utf16.count),
            selectionLength: 0
        )
        let editor = iPadTextEditor(
            text: Binding(get: { text }, set: { text = $0 }),
            documentID: DocumentID(rawValue: UUID()),
            externalVersion: 0,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusRequest: 0
        )
        let coordinator = editor.makeCoordinator()
        let textView = SmartTextView(frame: window.bounds)
        textView.delegate = coordinator
        host.view.addSubview(textView)
        coordinator.applyExternalState(to: textView)
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        textView.layoutIfNeeded()
        textView.layoutIfNeeded()
        let fullLayoutCount = textView.fullDocumentLayoutCount

        XCTAssertTrue(textView.layoutManager.allowsNonContiguousLayout)
        XCTAssertTrue(textView.becomeFirstResponder())
        textView.insertText("가")
        textView.layoutIfNeeded()

        XCTAssertFalse(text.hasSuffix("가"), "입력 중 전체 String 바인딩은 그대로 둔다")
        XCTAssertTrue(textView.text.hasSuffix("가"))
        XCTAssertEqual(textView.fullDocumentLayoutCount, fullLayoutCount)
    }

    @MainActor
    func testHundredThousandCharacterTypingIdleDefersWholeLayoutUntilScrolling() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        let host = UIViewController()
        window.rootViewController = host
        var text = String(
            repeating: "10만 자 원고 입력 중에는 전체 레이아웃을 미룹니다.\n",
            count: 5_000
        )
        var selection = TextCursorState(
            location: UInt(text.utf16.count),
            selectionLength: 0
        )
        let editor = iPadTextEditor(
            text: Binding(get: { text }, set: { text = $0 }),
            documentID: DocumentID(rawValue: UUID()),
            externalVersion: 0,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusRequest: 0
        )
        let coordinator = editor.makeCoordinator()
        let textView = SmartTextView(frame: window.bounds)
        textView.delegate = coordinator
        host.view.addSubview(textView)
        coordinator.applyExternalState(to: textView)
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        textView.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertGreaterThan(text.utf16.count, 100_000)
        let preparationCount = textView.documentEndLayoutPreparationCount
        XCTAssertTrue(textView.becomeFirstResponder())
        textView.insertText("가")
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertFalse(text.hasSuffix("가"), "입력 중 전체 String 바인딩은 그대로 둔다")
        XCTAssertTrue(textView.text.hasSuffix("가"))
        XCTAssertEqual(
            textView.documentEndLayoutPreparationCount,
            preparationCount
        )

        coordinator.scrollViewWillBeginDragging(textView)
        XCTAssertEqual(
            textView.documentEndLayoutPreparationCount,
            preparationCount + 1
        )
    }

    @MainActor
    func testSmartTextViewClampsSelectionAndKeepsPlaceholderOutOfText() {
        let textView = SmartTextView()
        textView.placeholderText = "빈 문서 안내"
        textView.applyExternalText(
            "가🙂",
            selection: TextCursorState(location: 999, selectionLength: 999),
            clearsUndoHistory: true
        )

        XCTAssertEqual(textView.text, "가🙂")
        XCTAssertEqual(textView.selectedRange.location, "가🙂".utf16.count)
        XCTAssertEqual(textView.selectedRange.length, 0)
        XCTAssertFalse(textView.text.contains("빈 문서 안내"))
    }

    @MainActor
    func testSmartTextViewKeepsScrollIndicatorClearOfSystemEdgeGesture() {
        let textView = SmartTextView()

        XCTAssertEqual(textView.verticalScrollIndicatorInsets.right, 20, accuracy: 0.01)
        XCTAssertEqual(textView.textContainerInset.right, 16, accuracy: 0.01)
    }

    @MainActor
    func testSmartTextViewUpdatesDynamicTextColorWithoutChangingManuscriptOrUndo() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let controller = UIViewController()
        let textView = SmartTextView(frame: window.bounds)
        controller.view.addSubview(textView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        textView.applyExternalText(
            "다크 모드 본문",
            selection: TextCursorState(location: 0, selectionLength: 0),
            clearsUndoHistory: true
        )

        window.overrideUserInterfaceStyle = .dark
        textView.refreshVisualAppearance()

        let textColor = try XCTUnwrap(
            textView.textStorage.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            ) as? UIColor
        )
        XCTAssertEqual(
            textColor.resolvedColor(with: textView.traitCollection),
            UIColor.label.resolvedColor(with: textView.traitCollection)
        )
        XCTAssertEqual(textView.text, "다크 모드 본문")
        XCTAssertFalse(try XCTUnwrap(textView.undoManager).canUndo)
    }

    @MainActor
    func testSearchHighlightsRemainVisualOnlyAndPreserveUndoAndPlainText() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let controller = UIViewController()
        let textView = SmartTextView(frame: window.bounds)
        controller.view.addSubview(textView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        textView.applyExternalText(
            "가🙂나🙂",
            selection: TextCursorState(location: 6, selectionLength: 0),
            clearsUndoHistory: true
        )
        XCTAssertTrue(textView.becomeFirstResponder())
        textView.insertText("끝")
        let originalText = try XCTUnwrap(textView.text)
        let originalBytes = Data(originalText.utf8)
        XCTAssertTrue(try XCTUnwrap(textView.undoManager).canUndo)

        let first = NSRange(location: 1, length: 2)
        let second = NSRange(location: 4, length: 2)
        textView.setTemporarySearchHighlights([first, second], current: second)

        XCTAssertEqual(textView.temporarySearchHighlightRanges, [first, second])
        XCTAssertEqual(textView.temporaryCurrentSearchHighlightRange, second)
        XCTAssertNotNil(textView.textStorage.attribute(.backgroundColor, at: 1, effectiveRange: nil))
        XCTAssertNotNil(textView.textStorage.attribute(.backgroundColor, at: 4, effectiveRange: nil))
        XCTAssertEqual(Data(try XCTUnwrap(textView.text).utf8), originalBytes)
        XCTAssertTrue(try XCTUnwrap(textView.undoManager).canUndo)

        textView.setTemporarySearchHighlights([])
        XCTAssertNil(textView.textStorage.attribute(.backgroundColor, at: 1, effectiveRange: nil))
        XCTAssertEqual(Data(try XCTUnwrap(textView.text).utf8), originalBytes)
        XCTAssertTrue(try XCTUnwrap(textView.undoManager).canUndo)
        textView.performUndo()
        XCTAssertEqual(textView.text, "가🙂나🙂")
    }

    @MainActor
    func testDocumentSearchFieldHandlesConsecutiveReturnsWithoutResigning() {
        var query = "한글"
        var isFocused = true
        var submitCount = 0
        let field = DocumentSearchTextField(
            text: Binding(get: { query }, set: { query = $0 }),
            isFocused: Binding(get: { isFocused }, set: { isFocused = $0 }),
            onSubmit: { submitCount += 1 },
            onCancel: {}
        )
        XCTAssertTrue(isFocused)
        XCTAssertEqual(query, "한글")

        let hardwareField = DocumentSearchUITextView()
        hardwareField.onHardwareReturn = { submitCount += 1 }
        hardwareField.insertText("\n")
        hardwareField.insertText("\r")
        hardwareField.insertText("\n")
        XCTAssertEqual(submitCount, 3)
        XCTAssertEqual(hardwareField.text, "")

        var cancelCount = 0
        hardwareField.onHardwareEscape = { cancelCount += 1 }
        let escapeCommands = hardwareField.keyCommands?.filter {
                $0.input == UIKeyCommand.inputEscape
                    && $0.modifierFlags.intersection(
                        [.command, .shift, .control, .alternate]
                    ).isEmpty
        }
        XCTAssertEqual(escapeCommands?.count, 1)
        XCTAssertTrue(escapeCommands?.first?.wantsPriorityOverSystemBehavior == true)
        hardwareField.handleHardwareEscape()
        hardwareField.insertText("\u{1B}")
        XCTAssertEqual(cancelCount, 2)
        XCTAssertEqual(hardwareField.text, "")
    }

    @MainActor
    func testEditorTabCommandPrioritizesPaneSwitchOverSystemFocus() throws {
        let textView = SmartTextView()
        let tabCommand = try XCTUnwrap(
            textView.keyCommands?.first {
                $0.input == "\t" && $0.modifierFlags.isEmpty
            }
        )

        XCTAssertEqual(tabCommand.discoverabilityTitle, "편집기 창 전환")
        XCTAssertTrue(tabCommand.wantsPriorityOverSystemBehavior)
    }

    @MainActor
    func testEditorExposesProjectSearchHardwareShortcut() throws {
        let textView = SmartTextView()
        let projectSearchCommand = try XCTUnwrap(
            textView.keyCommands?.first {
                $0.input == "f"
                    && $0.modifierFlags.intersection(
                        [.command, .shift, .control, .alternate]
                    ) == [.command, .shift]
            }
        )

        XCTAssertEqual(projectSearchCommand.discoverabilityTitle, "작품 전체에서 찾기")
    }

    @MainActor
    func testEditorUsesSystemUndoRedoAndRegistersOnlyBracketNavigation() {
        let commands = SmartTextView().keyCommands ?? []
        let relevantModifiers: UIKeyModifierFlags = [
            .command, .shift, .control, .alternate
        ]

        func matching(
            input: String,
            modifiers: UIKeyModifierFlags
        ) -> [UIKeyCommand] {
            commands.filter {
                $0.input == input
                    && $0.modifierFlags.intersection(relevantModifiers) == modifiers
            }
        }

        XCTAssertTrue(matching(input: "z", modifiers: .command).isEmpty)
        XCTAssertTrue(matching(input: "z", modifiers: [.command, .shift]).isEmpty)
        XCTAssertEqual(
            matching(input: "[", modifiers: .command)
                .map(\.discoverabilityTitle),
            ["이전 화"]
        )
        XCTAssertEqual(
            matching(input: "]", modifiers: .command)
                .map(\.discoverabilityTitle),
            ["다음 화"]
        )
        XCTAssertTrue(
            matching(
                input: UIKeyCommand.inputLeftArrow,
                modifiers: [.command, .alternate]
            ).isEmpty
        )
        XCTAssertTrue(
            matching(
                input: UIKeyCommand.inputRightArrow,
                modifiers: [.command, .alternate]
            ).isEmpty
        )
    }

    @MainActor
    func testEditorAppearanceChangesOnlyVisualAttributesAndPreservesUndo() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let controller = UIViewController()
        let textView = SmartTextView(frame: window.bounds)
        controller.view.addSubview(textView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        textView.applyExternalText(
            "원고",
            selection: TextCursorState(location: 2, selectionLength: 0),
            clearsUndoHistory: true
        )
        XCTAssertTrue(textView.becomeFirstResponder())
        textView.insertText("🙂")
        let originalText = try XCTUnwrap(textView.text)
        let originalBytes = Data(originalText.utf8)
        let originalSelection = textView.selectedRange
        let assignmentCount = textView.fullTextAssignmentCount
        XCTAssertTrue(try XCTUnwrap(textView.undoManager).canUndo)

        let appearance = EditorAppearanceSettings(
            fontFamily: .serif,
            fontSize: 24,
            lineSpacing: 12,
            horizontalInset: 42,
            verticalInset: 36,
            typewriterScrolling: true
        )
        textView.applyAppearance(appearance)

        XCTAssertEqual(textView.text, originalText)
        XCTAssertEqual(Data(textView.text.utf8), originalBytes)
        XCTAssertEqual(textView.selectedRange, originalSelection)
        XCTAssertEqual(textView.fullTextAssignmentCount, assignmentCount)
        XCTAssertEqual(textView.textContainerInset.left, 42, accuracy: 0.01)
        XCTAssertEqual(textView.textContainerInset.top, 36, accuracy: 0.01)
        let paragraphStyle = try XCTUnwrap(
            textView.textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                as? NSParagraphStyle
        )
        let appliedFont = try XCTUnwrap(textView.font)
        XCTAssertEqual(paragraphStyle.lineHeightMultiple, 1, accuracy: 0.001)
        XCTAssertEqual(
            paragraphStyle.lineSpacing,
            appliedFont.lineHeight * 0.72,
            accuracy: 0.001
        )
        let kern = try XCTUnwrap(
            textView.textStorage.attribute(.kern, at: 0, effectiveRange: nil) as? NSNumber
        )
        XCTAssertEqual(kern.doubleValue, -0.5, accuracy: 0.001)
        XCTAssertTrue(try XCTUnwrap(textView.undoManager).canUndo)

        textView.applyExternalText(
            "교체된 원고",
            selection: TextCursorState(location: 6, selectionLength: 0),
            clearsUndoHistory: true
        )
        textView.applyAppearance(appearance)

        let reappliedFont = try XCTUnwrap(
            textView.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        )
        let editorFont = try XCTUnwrap(textView.font)
        XCTAssertEqual(reappliedFont.pointSize, editorFont.pointSize, accuracy: 0.01)
        XCTAssertEqual(textView.text, "교체된 원고")

        textView.applyExternalText(
            originalText,
            selection: TextCursorState(
                location: UInt(originalSelection.location),
                selectionLength: UInt(originalSelection.length)
            ),
            clearsUndoHistory: true
        )
        textView.applyAppearance(appearance)
        XCTAssertTrue(textView.becomeFirstResponder())
        textView.insertText("!")
        textView.performUndo()
        XCTAssertEqual(textView.text, originalText)
    }

    func testEditorAppearanceSanitizesPersistedNumericValues() {
        let appearance = EditorAppearanceSettings(
            fontFamily: .monospaced,
            fontSize: .infinity,
            lineSpacing: -100,
            horizontalInset: 500,
            verticalInset: .nan,
            typewriterScrolling: true
        )

        XCTAssertEqual(appearance.fontSize, 17)
        XCTAssertEqual(appearance.lineSpacing, -60)
        XCTAssertEqual(appearance.horizontalInset, 120)
        XCTAssertEqual(appearance.verticalInset, 30)
        XCTAssertTrue(appearance.typewriterScrolling)
    }

    @MainActor
    func testBundledMalgunFontsApplyWithoutChangingManuscriptText() throws {
        XCTAssertEqual(EditorAppearanceSettings.default.fontFamily, .system)
        let textView = SmartTextView()
        textView.applyExternalText(
            "맑은 고딕 원고",
            selection: .start,
            clearsUndoHistory: true
        )
        let appearance = EditorAppearanceSettings(
            fontFamily: .malgunGothicBold,
            fontSize: 20,
            lineSpacing: 6,
            horizontalInset: 20,
            verticalInset: 18,
            typewriterScrolling: false
        )

        textView.applyAppearance(appearance)

        XCTAssertEqual(textView.text, "맑은 고딕 원고")
        XCTAssertEqual(textView.font?.fontName, "MalgunGothicBold")
        XCTAssertTrue(
            textView.font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true
        )
        XCTAssertEqual(EditorFontFamily.malgunGothicSemilight.bundledPostScriptName, "MalgunGothic-Semilight")
    }

    func testTypewriterScrollCentersAndClampsAtDocumentEdges() {
        XCTAssertEqual(
            TypewriterScrollPosition.targetY(
                caretMidY: 900,
                viewportHeight: 600,
                contentHeight: 2_000,
                topInset: 20,
                bottomInset: 20
            ),
            600
        )
        XCTAssertEqual(
            TypewriterScrollPosition.targetY(
                caretMidY: 10,
                viewportHeight: 600,
                contentHeight: 2_000,
                topInset: 20,
                bottomInset: 20
            ),
            -20
        )
        XCTAssertEqual(
            TypewriterScrollPosition.targetY(
                caretMidY: 5_000,
                viewportHeight: 600,
                contentHeight: 2_000,
                topInset: 20,
                bottomInset: 20
            ),
            1_420
        )
    }

    @MainActor
    func testTypewriterTextChangeUsesOneSynchronousLayoutPass() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let host = UIViewController()
        let textView = SmartTextView(frame: window.bounds)
        host.view.addSubview(textView)
        window.rootViewController = host
        window.makeKeyAndVisible()
        let text = (1...100).map { "\($0)번째 문장" }.joined(separator: "\n")
        let editor = iPadTextEditor(
            text: .constant(text),
            documentID: DocumentID(rawValue: UUID()),
            externalVersion: 1,
            selection: .constant(.start),
            focusRequest: 0,
            appearance: EditorAppearanceSettings(
                fontFamily: .system,
                fontSize: 18,
                lineSpacing: 6,
                horizontalInset: 20,
                verticalInset: 18,
                typewriterScrolling: true
            )
        )
        let coordinator = editor.makeCoordinator()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)
        textView.layoutIfNeeded()
        textView.selectedRange = NSRange(location: text.utf16.count / 2, length: 0)
        let previousCount = coordinator.typewriterSynchronousLayoutCount

        coordinator.textViewDidChange(textView)

        XCTAssertEqual(coordinator.typewriterSynchronousLayoutCount, previousCount + 1)
        XCTAssertEqual(textView.text, text)
    }

    @MainActor
    func testLargeManuscriptTypingSkipsSynchronousTypewriterLayout() {
        let textView = SmartTextView()
        textView.text = String(
            repeating: "가",
            count: iPadTextEditor.Coordinator.maximumSynchronousTypewriterUTF16Length + 1
        )
        let editor = iPadTextEditor(
            text: .constant(""),
            documentID: DocumentID(rawValue: UUID()),
            externalVersion: 1,
            selection: .constant(.start),
            focusRequest: 0,
            appearance: EditorAppearanceSettings(
                fontFamily: .system,
                fontSize: 18,
                lineSpacing: 6,
                horizontalInset: 20,
                verticalInset: 18,
                typewriterScrolling: true
            )
        )
        let coordinator = editor.makeCoordinator()
        let previousCount = coordinator.typewriterSynchronousLayoutCount

        coordinator.textViewDidChange(textView)

        XCTAssertEqual(coordinator.typewriterSynchronousLayoutCount, previousCount)
    }

    func testLargeBackupPreviewBoundsRenderedTextAndDisablesDetailedDiff() {
        let source = String(
            repeating: "가",
            count: BackupPreviewContent.maximumDiffUTF16Length + 1
        )

        let preview = BackupPreviewContent(backup: source)

        XCTAssertFalse(preview.allowsDetailedDiff)
        XCTAssertLessThan(
            (preview.preview as NSString).length,
            BackupPreviewContent.maximumPreviewUTF16Length + 32
        )
        XCTAssertTrue(preview.preview.hasSuffix("… (일부 미리보기)"))
    }

    @MainActor
    func testPhysicalArrowKeysAfterNewlinePrepareNearbyLayoutAndRecenter() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let host = UIViewController()
        let textView = SmartTextView(frame: window.bounds)
        host.view.addSubview(textView)
        window.rootViewController = host
        window.makeKeyAndVisible()

        let paragraph = "안녕하세요\n\n"
        let text = String(repeating: paragraph, count: 9_000)
        let editor = iPadTextEditor(
            text: .constant(text),
            documentID: DocumentID(rawValue: UUID()),
            externalVersion: 1,
            selection: .constant(.start),
            focusRequest: 0,
            appearance: EditorAppearanceSettings(
                fontFamily: .system,
                fontSize: 17,
                lineSpacing: 6,
                horizontalInset: 64,
                verticalInset: 30,
                typewriterScrolling: true
            )
        )
        let coordinator = editor.makeCoordinator()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)
        textView.layoutIfNeeded()

        let location = paragraph.utf16.count * 900 + "안녕하세요\n".utf16.count
        textView.selectedRange = NSRange(location: location, length: 0)
        textView.textStorage.replaceCharacters(
            in: textView.selectedRange,
            with: "입력"
        )
        textView.selectedRange = NSRange(location: location + 2, length: 0)
        coordinator.textViewDidChange(textView)
        textView.textStorage.replaceCharacters(
            in: textView.selectedRange,
            with: "\n"
        )
        textView.selectedRange = NSRange(location: location + 3, length: 0)
        coordinator.textViewDidChange(textView)
        textView.layoutIfNeeded()

        let preparationCount = textView.directionalNavigationLayoutPreparationCount
        textView.prepareDirectionalNavigationLayout()
        XCTAssertEqual(
            textView.directionalNavigationLayoutPreparationCount,
            preparationCount + 1
        )

        textView.setContentOffset(
            CGPoint(x: 0, y: textView.contentOffset.y + textView.bounds.height),
            animated: false
        )
        textView.selectedRange = NSRange(location: location + 4, length: 0)
        textView.isHandlingDirectionalArrowKey = true
        coordinator.textViewDidChangeSelection(textView)
        textView.isHandlingDirectionalArrowKey = false

        var selection = try XCTUnwrap(textView.selectedTextRange)
        var caret = textView.caretRect(for: selection.end)
        var visibleMidY = textView.contentOffset.y + textView.bounds.height / 2
        XCTAssertEqual(caret.midY, visibleMidY, accuracy: 36)

        textView.prepareDirectionalNavigationLayout()
        textView.setContentOffset(
            CGPoint(x: 0, y: max(0, textView.contentOffset.y - textView.bounds.height)),
            animated: false
        )
        textView.selectedRange = NSRange(location: location + 3, length: 0)
        textView.isHandlingDirectionalArrowKey = true
        coordinator.textViewDidChangeSelection(textView)
        textView.isHandlingDirectionalArrowKey = false

        selection = try XCTUnwrap(textView.selectedTextRange)
        caret = textView.caretRect(for: selection.end)
        visibleMidY = textView.contentOffset.y + textView.bounds.height / 2
        XCTAssertEqual(caret.midY, visibleMidY, accuracy: 36)
        XCTAssertEqual(
            textView.directionalNavigationLayoutPreparationCount,
            preparationCount + 2
        )

        textView.prepareDirectionalNavigationLayout()
        textView.setContentOffset(
            CGPoint(x: 0, y: textView.contentOffset.y + textView.bounds.height),
            animated: false
        )
        textView.selectedRange = NSRange(location: location + 2, length: 0)
        textView.isHandlingDirectionalArrowKey = true
        coordinator.textViewDidChangeSelection(textView)
        textView.isHandlingDirectionalArrowKey = false

        selection = try XCTUnwrap(textView.selectedTextRange)
        caret = textView.caretRect(for: selection.end)
        visibleMidY = textView.contentOffset.y + textView.bounds.height / 2
        XCTAssertEqual(caret.midY, visibleMidY, accuracy: 36)

        textView.prepareDirectionalNavigationLayout()
        textView.setContentOffset(
            CGPoint(x: 0, y: max(0, textView.contentOffset.y - textView.bounds.height)),
            animated: false
        )
        textView.selectedRange = NSRange(location: location + 3, length: 0)
        textView.isHandlingDirectionalArrowKey = true
        coordinator.textViewDidChangeSelection(textView)
        textView.isHandlingDirectionalArrowKey = false

        selection = try XCTUnwrap(textView.selectedTextRange)
        caret = textView.caretRect(for: selection.end)
        visibleMidY = textView.contentOffset.y + textView.bounds.height / 2
        XCTAssertEqual(caret.midY, visibleMidY, accuracy: 36)
        XCTAssertEqual(
            textView.directionalNavigationLayoutPreparationCount,
            preparationCount + 4
        )
    }

    @MainActor
    func testTypewriterScrollKeepsLastLineNearViewportCenter() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let host = UIViewController()
        let textView = SmartTextView(frame: window.bounds)
        host.view.addSubview(textView)
        window.rootViewController = host
        window.makeKeyAndVisible()

        let text = (1...120).map { "\($0)번째 원고 문장입니다." }.joined(separator: "\n")
        let appearance = EditorAppearanceSettings(
            fontFamily: .malgunGothic,
            fontSize: 18,
            lineSpacing: 6,
            horizontalInset: 20,
            verticalInset: 18,
            typewriterScrolling: true
        )
        let editor = iPadTextEditor(
            text: .constant(text),
            documentID: DocumentID(rawValue: UUID()),
            externalVersion: 1,
            selection: .constant(.start),
            focusRequest: 0,
            appearance: appearance
        )
        let coordinator = editor.makeCoordinator()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)
        textView.layoutIfNeeded()
        let viewportRestored = expectation(description: "초기 커서 화면 위치 확정")
        DispatchQueue.main.async {
            DispatchQueue.main.async { viewportRestored.fulfill() }
        }
        await fulfillment(of: [viewportRestored], timeout: 1)

        textView.selectedRange = NSRange(location: text.utf16.count, length: 0)
        coordinator.textViewDidChange(textView)
        let scrollingSettled = expectation(description: "타자기 스크롤 레이아웃 반영")
        DispatchQueue.main.async { scrollingSettled.fulfill() }
        await fulfillment(of: [scrollingSettled], timeout: 1)

        let selection = try XCTUnwrap(textView.selectedTextRange)
        let caret = textView.caretRect(for: selection.end)
        let visibleMidY = textView.contentOffset.y + textView.bounds.height / 2
        XCTAssertGreaterThan(textView.contentInset.bottom, textView.bounds.height * 0.35)
        XCTAssertEqual(caret.midY, visibleMidY, accuracy: 36)
        XCTAssertEqual(textView.text, text)

        textView.selectedRange = NSRange(location: text.utf16.count, length: 0)
        textView.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
        let caretTapOffset = textView.contentOffset
        coordinator.textViewDidChangeSelection(textView)
        let caretTapSettled = expectation(description: "단순 커서 탭 스크롤 유지")
        DispatchQueue.main.async { caretTapSettled.fulfill() }
        await fulfillment(of: [caretTapSettled], timeout: 1)
        XCTAssertEqual(textView.contentOffset.y, caretTapOffset.y, accuracy: 0.5)

        textView.selectedRange = NSRange(location: 0, length: text.utf16.count)
        textView.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
        let selectionDragOffset = textView.contentOffset
        coordinator.textViewDidChangeSelection(textView)
        let selectionSettled = expectation(description: "범위 선택 스크롤 유지")
        DispatchQueue.main.async { selectionSettled.fulfill() }
        await fulfillment(of: [selectionSettled], timeout: 1)
        XCTAssertEqual(textView.contentOffset.y, selectionDragOffset.y, accuracy: 0.5)
        XCTAssertEqual(textView.text, text)

        textView.selectedRange = NSRange(location: text.utf16.count, length: 0)
        textView.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
        let sameLineOffset = textView.contentOffset
        coordinator.textViewDidChange(textView)
        let typingSettled = expectation(description: "동일 줄 입력 화면 유지")
        DispatchQueue.main.async { typingSettled.fulfill() }
        await fulfillment(of: [typingSettled], timeout: 1)
        XCTAssertEqual(textView.contentOffset.y, sameLineOffset.y, accuracy: 0.5)

        let middleLocation = text.utf16.count / 2
        textView.selectedRange = NSRange(location: middleLocation, length: 0)
        textView.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        textView.textStorage.replaceCharacters(
            in: NSRange(location: middleLocation, length: 0),
            with: "새"
        )
        textView.selectedRange = NSRange(location: middleLocation + 1, length: 0)
        coordinator.textViewDidChange(textView)

        let middleSelection = try XCTUnwrap(textView.selectedTextRange)
        let middleCaret = textView.caretRect(for: middleSelection.end)
        let middleVisibleMidY = textView.contentOffset.y + textView.bounds.height / 2
        let stabilizedOffset = textView.contentOffset
        XCTAssertEqual(middleCaret.midY, middleVisibleMidY, accuracy: 36)

        await Task.yield()
        textView.layoutIfNeeded()
        XCTAssertEqual(textView.contentOffset.y, stabilizedOffset.y, accuracy: 0.5)

        textView.selectedRange = NSRange(location: middleLocation + 1, length: 0)
        textView.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        XCTAssertTrue(
            coordinator.textView(
                textView,
                shouldChangeTextIn: textView.selectedRange,
                replacementText: "ㅎ"
            )
        )
        textView.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0))
        coordinator.textViewDidChange(textView)
        XCTAssertNotNil(textView.markedTextRange)
        let firstJamoOffset = textView.contentOffset

        XCTAssertTrue(
            coordinator.textView(
                textView,
                shouldChangeTextIn: textView.selectedRange,
                replacementText: "ㅏ"
            )
        )
        textView.setMarkedText("하", selectedRange: NSRange(location: 1, length: 0))
        coordinator.textViewDidChange(textView)
        XCTAssertNotNil(textView.markedTextRange)
        XCTAssertEqual(textView.contentOffset.y, firstJamoOffset.y, accuracy: 0.5)

        textView.unmarkText()
        coordinator.textViewDidChange(textView)
        XCTAssertEqual(textView.contentOffset.y, firstJamoOffset.y, accuracy: 0.5)

        let textBeforeDisabling = textView.text
        let disabledAppearance = EditorAppearanceSettings(
            fontFamily: .malgunGothic,
            fontSize: 18,
            lineSpacing: 6,
            horizontalInset: 20,
            verticalInset: 18,
            typewriterScrolling: false
        )
        coordinator.parent = iPadTextEditor(
            text: .constant(text),
            documentID: editor.documentID,
            externalVersion: 1,
            selection: .constant(.start),
            focusRequest: 0,
            appearance: disabledAppearance
        )
        coordinator.applyExternalState(to: textView)
        let disablingSettled = expectation(description: "타자기 스크롤 해제 반영")
        DispatchQueue.main.async { disablingSettled.fulfill() }
        await fulfillment(of: [disablingSettled], timeout: 1)
        XCTAssertEqual(textView.contentInset.bottom, 0, accuracy: 0.5)
        XCTAssertEqual(textView.text, textBeforeDisabling)
    }

    @MainActor
    func testSoftWrappedDocumentRemainsScrollableAfterDocumentRoundTrip() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let host = UIViewController()
        let textView = SmartTextView(frame: window.bounds)
        host.view.addSubview(textView)
        window.rootViewController = host
        window.makeKeyAndVisible()

        let source = "그래 이거지~~ㅇㄴㅁㅇㄴㅁㅇㅁㅇㅁㅇㅁㅇㅁㅇㅁㅌㄴㅋㅂㅋㅁㅂㅋㅁㅂㅋㅂㅋㅂㅋㅂㅋㅁㅂㅋㅁㅂㅋㅂㅋㅂㅋㅂㅋㅂㅋㅂㅋㅂ"
        let longText = String(repeating: source, count: 13)
        let longDocumentID = DocumentID(rawValue: UUID())
        let shortDocumentID = DocumentID(rawValue: UUID())
        let appearance = EditorAppearanceSettings(
            fontFamily: .system,
            fontSize: 17,
            lineSpacing: 6,
            horizontalInset: 64,
            verticalInset: 30,
            typewriterScrolling: true
        )

        func editor(
            text: String,
            documentID: DocumentID,
            selection: TextCursorState = .start
        ) -> iPadTextEditor {
            iPadTextEditor(
                text: .constant(text),
                documentID: documentID,
                externalVersion: 1,
                selection: .constant(selection),
                focusRequest: 0,
                appearance: appearance
            )
        }

        let coordinator = editor(text: longText, documentID: longDocumentID).makeCoordinator()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)
        textView.layoutIfNeeded()
        await Task.yield()
        textView.layoutIfNeeded()

        XCTAssertGreaterThan(textView.contentSize.height, textView.bounds.height)

        coordinator.parent = editor(text: "다른 화", documentID: shortDocumentID)
        coordinator.applyExternalState(to: textView)
        await Task.yield()
        textView.layoutIfNeeded()

        let restoredCursor = TextCursorState(
            location: UInt(longText.utf16.count * 3 / 4),
            selectionLength: 0
        )
        coordinator.parent = editor(
            text: longText,
            documentID: longDocumentID,
            selection: restoredCursor
        )
        coordinator.applyExternalState(to: textView)
        XCTAssertEqual(textView.alpha, 0, accuracy: 0.01)
        let viewportRestored = expectation(description: "저장된 커서 화면 위치 확정")
        DispatchQueue.main.async {
            DispatchQueue.main.async { viewportRestored.fulfill() }
        }
        await fulfillment(of: [viewportRestored], timeout: 1)
        let restoredSelection = try XCTUnwrap(textView.selectedTextRange)
        let restoredCaret = textView.caretRect(for: restoredSelection.end)
        let restoredVisibleMidY = textView.contentOffset.y + textView.bounds.height / 2
        XCTAssertEqual(restoredCaret.midY, restoredVisibleMidY, accuracy: 36)
        XCTAssertGreaterThan(textView.contentOffset.y, 0)
        XCTAssertEqual(textView.alpha, 1, accuracy: 0.01)
        await Task.yield()
        textView.layoutIfNeeded()
        await Task.yield()
        textView.layoutIfNeeded()

        let maximumOffset = max(
            0,
            textView.contentSize.height
                - textView.bounds.height
                + textView.adjustedContentInset.bottom
        )
        XCTAssertGreaterThan(textView.contentSize.height, textView.bounds.height)
        XCTAssertGreaterThan(maximumOffset, 100)

        textView.setContentOffset(CGPoint(x: 0, y: min(180, maximumOffset)), animated: false)
        XCTAssertGreaterThan(textView.contentOffset.y, 0)
        XCTAssertTrue(textView.showsVerticalScrollIndicator)
    }

    @MainActor
    func testMidDocumentTypingRefreshesScrollRangeWithoutMovingViewport() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let host = UIViewController()
        let textView = SmartTextView(frame: window.bounds)
        host.view.addSubview(textView)
        window.rootViewController = host
        window.makeKeyAndVisible()

        let text = String(repeating: "중간 위치 입력 중에도 화면은 안정적이어야 합니다.\n", count: 2_000)
        let documentID = DocumentID(rawValue: UUID())
        let editor = iPadTextEditor(
            text: .constant(text),
            documentID: documentID,
            externalVersion: 1,
            selection: .constant(.start),
            focusRequest: 0,
            appearance: EditorAppearanceSettings(
                fontFamily: .system,
                fontSize: 17,
                lineSpacing: 6,
                horizontalInset: 64,
                verticalInset: 30,
                typewriterScrolling: true
            )
        )
        let coordinator = editor.makeCoordinator()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)
        textView.layoutIfNeeded()
        let viewportRestored = expectation(description: "초기 커서 화면 위치 확정")
        DispatchQueue.main.async {
            DispatchQueue.main.async { viewportRestored.fulfill() }
        }
        await fulfillment(of: [viewportRestored], timeout: 1)
        _ = textView.becomeFirstResponder()

        let insertionLocation = text.utf16.count / 2
        textView.selectedRange = NSRange(location: insertionLocation, length: 0)
        textView.setContentOffset(CGPoint(x: 0, y: 240), animated: false)
        textView.textStorage.replaceCharacters(
            in: NSRange(location: insertionLocation, length: 0),
            with: "새"
        )
        textView.selectedRange = NSRange(location: insertionLocation + 1, length: 0)

        coordinator.textViewDidChange(textView)
        textView.layoutIfNeeded()
        let stabilizedOffsetAfterNativeEdit = textView.contentOffset
        await Task.yield()
        textView.layoutIfNeeded()

        XCTAssertEqual(
            textView.contentOffset.y,
            stabilizedOffsetAfterNativeEdit.y,
            accuracy: 0.5
        )
        XCTAssertGreaterThan(textView.contentSize.height, textView.bounds.height)
        textView.layoutManager.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: textView.textStorage.length),
            actualCharacterRange: nil
        )
        textView.prepareDocumentEndLayout()
        XCTAssertEqual(
            textView.contentOffset.y,
            stabilizedOffsetAfterNativeEdit.y,
            accuracy: 0.5
        )
        try await Task.sleep(for: .milliseconds(350))
        textView.layoutIfNeeded()
        XCTAssertEqual(
            textView.contentOffset.y,
            stabilizedOffsetAfterNativeEdit.y,
            accuracy: 0.5
        )

        let newlineLocation = insertionLocation + 1
        textView.setContentOffset(CGPoint(x: 0, y: 240), animated: false)
        textView.textStorage.replaceCharacters(
            in: NSRange(location: newlineLocation, length: 0),
            with: "\n"
        )
        textView.selectedRange = NSRange(location: newlineLocation + 1, length: 0)

        coordinator.textViewDidChange(textView)
        textView.layoutIfNeeded()
        let stabilizedOffsetAfterNativeNewline = textView.contentOffset
        await Task.yield()
        textView.layoutIfNeeded()

        XCTAssertEqual(
            textView.contentOffset.y,
            stabilizedOffsetAfterNativeNewline.y,
            accuracy: 0.5
        )
        XCTAssertGreaterThan(textView.contentSize.height, textView.bounds.height)
        try await Task.sleep(for: .milliseconds(350))
        textView.layoutIfNeeded()
        XCTAssertEqual(
            textView.contentOffset.y,
            stabilizedOffsetAfterNativeNewline.y,
            accuracy: 0.5
        )
    }

    @MainActor
    func testLongDocumentScrollRangeStaysStableAfterMidDocumentEdit() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let host = UIViewController()
        let textView = SmartTextView(frame: window.bounds)
        host.view.addSubview(textView)
        window.rootViewController = host
        window.makeKeyAndVisible()

        let text = String(repeating: "긴 원고 스크롤 범위를 유지해야 합니다.\n", count: 2_000)
        let editor = iPadTextEditor(
            text: .constant(text),
            documentID: DocumentID(rawValue: UUID()),
            externalVersion: 1,
            selection: .constant(.start),
            focusRequest: 0,
            appearance: EditorAppearanceSettings(
                fontFamily: .system,
                fontSize: 17,
                lineSpacing: 6,
                horizontalInset: 64,
                verticalInset: 30,
                typewriterScrolling: false
            )
        )
        let coordinator = editor.makeCoordinator()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)
        textView.layoutIfNeeded()
        let viewportRestored = expectation(description: "초기 커서 화면 위치 확정")
        DispatchQueue.main.async {
            DispatchQueue.main.async { viewportRestored.fulfill() }
        }
        await fulfillment(of: [viewportRestored], timeout: 1)
        textView.layoutIfNeeded()

        let initialHeight = textView.contentSize.height
        let insertionLocation = text.utf16.count / 2
        textView.textStorage.replaceCharacters(
            in: NSRange(location: insertionLocation, length: 0),
            with: "수정"
        )
        textView.selectedRange = NSRange(location: insertionLocation + 2, length: 0)
        coordinator.textViewDidChange(textView)
        textView.layoutIfNeeded()
        let endPreparationCountBeforeDrag = textView.documentEndLayoutPreparationCount
        coordinator.scrollViewWillBeginDragging(textView)
        let preparedHeight = textView.contentSize.height
        var heightsWhileScrolling: [CGFloat] = []

        for fraction in [0.25, 0.5, 0.75, 1.0] {
            let maximumOffset = max(
                0,
                textView.contentSize.height
                    - textView.bounds.height
                    + textView.adjustedContentInset.bottom
            )
            textView.setContentOffset(
                CGPoint(x: 0, y: maximumOffset * fraction),
                animated: false
            )
            textView.layoutIfNeeded()
            heightsWhileScrolling.append(textView.contentSize.height)
        }

        XCTAssertGreaterThan(initialHeight, textView.bounds.height * 20)
        XCTAssertEqual(
            textView.documentEndLayoutPreparationCount,
            endPreparationCountBeforeDrag + 2
        )
        XCTAssertGreaterThanOrEqual(textView.contentSize.height, initialHeight - 1)
        XCTAssertTrue(
            heightsWhileScrolling.allSatisfy {
                abs($0 - preparedHeight) <= 1
            },
            "스크롤 중 문서 높이가 변경됐습니다: prepared=\(preparedHeight), observed=\(heightsWhileScrolling)"
        )
        let finalMaximumOffset = textView.contentSize.height
            - textView.bounds.height
            + textView.adjustedContentInset.bottom
        XCTAssertEqual(textView.contentOffset.y, finalMaximumOffset, accuracy: 1)
    }

    @MainActor
    func testFastScrollbarJumpFinalizesPendingWholeDocumentLayout() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let host = UIViewController()
        let textView = SmartTextView(frame: window.bounds)
        host.view.addSubview(textView)
        window.rootViewController = host
        window.makeKeyAndVisible()

        let text = String(repeating: "빠른 막대 이동에서도 중간 줄 높이가 빠지면 안 됩니다.\n", count: 2_000)
        let editor = iPadTextEditor(
            text: .constant(text),
            documentID: DocumentID(rawValue: UUID()),
            externalVersion: 1,
            selection: .constant(
                TextCursorState(
                    location: UInt(text.utf16.count),
                    selectionLength: 0
                )
            ),
            focusRequest: 0,
            appearance: EditorAppearanceSettings(
                fontFamily: .system,
                fontSize: 17,
                lineSpacing: 6,
                horizontalInset: 64,
                verticalInset: 30,
                typewriterScrolling: false
            )
        )
        let coordinator = editor.makeCoordinator()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)
        textView.layoutIfNeeded()
        let viewportRestored = expectation(description: "최하단 커서 복원 완료")
        DispatchQueue.main.async {
            DispatchQueue.main.async { viewportRestored.fulfill() }
        }
        await fulfillment(of: [viewportRestored], timeout: 1)
        textView.layoutIfNeeded()

        let wholeRange = NSRange(location: 0, length: textView.textStorage.length)
        textView.layoutManager.invalidateLayout(
            forCharacterRange: wholeRange,
            actualCharacterRange: nil
        )
        coordinator.scrollViewWillBeginDragging(textView)
        let preparedHeight = textView.contentSize.height

        textView.setContentOffset(.zero, animated: false)
        let minimumOffset = -textView.adjustedContentInset.top
        let preparedMaximumOffset = max(
            minimumOffset,
            preparedHeight
                - textView.bounds.height
                + textView.adjustedContentInset.bottom
        )
        textView.setContentOffset(
            CGPoint(
                x: 0,
                y: minimumOffset
                    + (preparedMaximumOffset - minimumOffset) * 0.9
            ),
            animated: false
        )
        textView.layoutIfNeeded()

        XCTAssertEqual(textView.contentSize.height, preparedHeight, accuracy: 1)
        let finalMaximumOffset = textView.contentSize.height
            - textView.bounds.height
            + textView.adjustedContentInset.bottom
        XCTAssertEqual(textView.contentOffset.y, finalMaximumOffset, accuracy: 1)
    }

    @MainActor
    func testHostedEditorKeepsSoftWrappedScrollRangeAfterDocumentRoundTrip() async throws {
        let source = "그래 이거지~~ㅇㄴㅁㅇㄴㅁㅇㅁㅇㅁㅇㅁㅇㅁㅇㅁㅌㄴㅋㅂㅋㅁㅂㅋㅁㅂㅋㅂㅋㅂㅋㅂㅋㅁㅂㅋㅁㅂㅋㅂㅋㅂㅋㅂㅋㅂㅋㅂㅋㅂ"
        let longText = String(repeating: source, count: 13)
        let longDocumentID = DocumentID(rawValue: UUID())
        let shortDocumentID = DocumentID(rawValue: UUID())
        let appearance = EditorAppearanceSettings(
            fontFamily: .system,
            fontSize: 17,
            lineSpacing: 6,
            horizontalInset: 64,
            verticalInset: 30,
            typewriterScrolling: true
        )

        func editor(text: String, documentID: DocumentID) -> iPadTextEditor {
            iPadTextEditor(
                text: .constant(text),
                documentID: documentID,
                externalVersion: 1,
                selection: .constant(.start),
                focusRequest: 0,
                appearance: appearance
            )
        }

        func smartTextView(in view: UIView) -> SmartTextView? {
            if let textView = view as? SmartTextView { return textView }
            return view.subviews.lazy.compactMap(smartTextView(in:)).first
        }

        let host = UIHostingController(rootView: editor(text: longText, documentID: longDocumentID))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await Task.yield()

        host.rootView = editor(text: "다른 화", documentID: shortDocumentID)
        host.view.layoutIfNeeded()
        await Task.yield()
        host.rootView = editor(text: longText, documentID: longDocumentID)
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()

        let textView = try XCTUnwrap(smartTextView(in: host.view))
        let maximumOffset = textView.contentSize.height
            - textView.bounds.height
            + textView.adjustedContentInset.bottom
        XCTAssertGreaterThan(textView.contentSize.height, textView.bounds.height)
        XCTAssertGreaterThan(maximumOffset, 100)

        textView.setContentOffset(CGPoint(x: 0, y: min(180, maximumOffset)), animated: false)
        XCTAssertGreaterThan(textView.contentOffset.y, 0)
    }

    func testManuscriptStatisticsCountsKoreanEmojiWhitespaceOncePerMeasurement() {
        XCTAssertEqual(
            ManuscriptStatistics(text: "한글 👩‍💻\n").characterCount,
            5
        )
        let largeDocument = String(repeating: "한글🙂\n", count: 1_500)
        measure {
            XCTAssertEqual(
                ManuscriptStatistics(text: largeDocument).characterCount,
                6_000
            )
        }
    }

    @MainActor
    func testEditorSessionCoalescesRapidStatisticsUpdatesIntoLatestResult() async throws {
        let environment = try AppEnvironment.testing()
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            workspaceStateRepository: environment.workspaceStateRepository
        )

        for index in 0..<25 {
            model.updateText("연속 입력 \(index)🙂")
        }
        let expectedText = "연속 입력 24🙂"

        XCTAssertEqual(model.text, expectedText)
        XCTAssertEqual(model.statistics, .empty)
        XCTAssertEqual(model.statisticsCalculationCount, 0)

        try await waitForStatistics(expectedText.count, in: model)

        XCTAssertEqual(model.statisticsCalculationCount, 1)
    }

    @MainActor
    func testEditorSessionCancelsStaleStatisticsAndCountsLatestLongManuscript() async throws {
        let environment = try AppEnvironment.testing()
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            workspaceStateRepository: environment.workspaceStateRepository
        )
        let longManuscript = String(repeating: "한글🙂\n", count: 50_000)

        model.updateText("폐기될 이전 원고")
        try await ContinuousClock().sleep(for: .milliseconds(75))
        model.updateText(longManuscript)

        try await waitForStatistics(200_000, in: model)

        XCTAssertEqual(model.text, longManuscript)
        XCTAssertEqual(model.statisticsCalculationCount, 1)
    }

    @MainActor
    /// 타이핑이 이어지는 동안에도 글자 수가 갱신되어야 하지만, 자판마다 전체를
    /// 다시 세면 긴 원고에서 입력이 밀린다. debounce와 최대 지연이 그 균형을
    /// 잡는다. 실제 시계로 재면 계산이 끼어들 틈이 밀리초 단위로 좁아 결과가
    /// 흔들리므로, 가상 시계로 시간을 직접 돌려 판정을 고정한다.
    func testEditorSessionRefreshesStatisticsDuringContinuousTyping() async throws {
        let environment = try AppEnvironment.testing()
        let clock = VirtualStatisticsClock()
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            workspaceStateRepository: environment.workspaceStateRepository,
            statisticsNow: { clock.now() },
            statisticsSleep: { duration in try await clock.sleep(for: duration) }
        )

        var wakeCount = 0
        for count in 1...9 {
            let sleeps = clock.sleepCount()
            model.updateText(String(repeating: "가", count: count))
            // 예약된 계산이 가상 시계에 대기를 걸기 전에 시간을 돌리면 그 대기는
            // 이미 지나간 마감을 잡아 영영 깨어나지 못한다. 등록을 확인한 뒤에만
            // 45ms를 진행시키고, 그때 깨어난 계산이 끝나야 다음 자판을 친다.
            // 다음 입력이 계산을 취소하는 경합이 사라져 몇 번 계산되는지가 시간
            // 계산만으로 정해진다.
            let registration = await clock.waitForSleep(after: sleeps)
            guard registration != .timedOut else {
                XCTFail("통계 계산 sleep 등록이 제한시간 안에 오지 않았다.")
                return
            }
            let woken = clock.advance(by: .milliseconds(45))
            wakeCount += woken
            if woken > 0 || registration == .completedWithoutSuspending {
                await model.awaitStatisticsForTesting()
            }
        }

        // 이 시험이 재려던 것은 "가상 시계를 돌리면 예약된 계산이 깨어난다"였다.
        // 대기가 등록되기 전에 시간을 돌리면 마감이 함께 밀려 한 번도 깨어나지
        // 못하고, 그래도 최대 지연을 넘긴 뒤의 즉시 계산 덕에 아래 단언들은
        // 통과해버린다. 그 잠복 결함을 여기서 붙잡는다.
        XCTAssertGreaterThan(
            wakeCount,
            0,
            "가상 시계를 돌린 것이 예약된 계산을 깨워야 한다."
        )
        XCTAssertGreaterThan(
            model.statisticsCalculationCount,
            0,
            "타이핑이 이어지는 동안에도 최소 한 번은 갱신되어야 한다."
        )
        XCTAssertGreaterThan(model.statistics.characterCount, 0)

        let pending = clock.advance(by: .seconds(1))
        XCTAssertGreaterThan(
            pending,
            0,
            "마지막 입력의 통계 계산이 예약되어 있어야 한다."
        )
        if pending > 0 {
            await model.awaitStatisticsForTesting()
        }

        XCTAssertEqual(model.statistics.characterCount, 9)
        XCTAssertLessThanOrEqual(
            model.statisticsCalculationCount,
            2,
            "자판마다 다시 세면 긴 원고에서 입력이 밀린다."
        )
    }

    func testVirtualStatisticsClockReportsSuspendedSleep() async throws {
        let clock = VirtualStatisticsClock(
            registrationBackstop: .milliseconds(50)
        )
        let previous = clock.sleepCount()
        let sleeper = Task {
            try await clock.sleep(for: .seconds(1))
        }

        let registration = await clock.waitForSleep(after: previous)

        XCTAssertEqual(registration, .suspended)
        XCTAssertEqual(clock.advance(by: .seconds(1)), 1)
        try await sleeper.value
    }

    func testVirtualStatisticsClockReportsCompletionWithoutSuspending()
        async throws {
        let clock = VirtualStatisticsClock(
            registrationBackstop: .milliseconds(50)
        )
        let previous = clock.sleepCount()

        try await clock.sleep(for: .zero)
        let registration = await clock.waitForSleep(after: previous)

        XCTAssertEqual(registration, .completedWithoutSuspending)
    }

    func testVirtualStatisticsClockReportsRegistrationTimeout() async {
        let clock = VirtualStatisticsClock(
            registrationBackstop: .milliseconds(5)
        )

        let registration = await clock.waitForSleep(after: clock.sleepCount())

        XCTAssertEqual(registration, .timedOut)
    }

    @MainActor
    func testSmartTextViewTypingParticipatesInUndo() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let controller = UIViewController()
        let textView = SmartTextView(frame: window.bounds)
        controller.view.addSubview(textView)
        window.rootViewController = controller
        window.makeKeyAndVisible()

        XCTAssertTrue(textView.becomeFirstResponder())
        textView.insertText("한글🙂")
        XCTAssertEqual(textView.text, "한글🙂")
        XCTAssertTrue(try XCTUnwrap(textView.undoManager).canUndo)

        textView.performUndo()
        XCTAssertEqual(textView.text, "")
    }

    @MainActor
    func testEditorCommandRequestsUndoAndRedoActiveTextView() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let controller = UIViewController()
        let textView = SmartTextView(frame: window.bounds)
        controller.view.addSubview(textView)
        window.rootViewController = controller
        window.makeKeyAndVisible()

        XCTAssertTrue(textView.becomeFirstResponder())
        var text = ""
        var selection = TextCursorState.start
        var editor = iPadTextEditor(
            text: Binding(get: { text }, set: { text = $0 }),
            documentID: DocumentID(rawValue: UUID()),
            externalVersion: 0,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusRequest: 0
        )
        let coordinator = iPadTextEditor.Coordinator(parent: editor)
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)
        textView.insertText("한글🙂")
        XCTAssertEqual(textView.text, "한글🙂")

        editor.undoRequest = 1
        coordinator.parent = editor
        coordinator.applyExternalState(to: textView)
        XCTAssertEqual(textView.text, "")
        editor.redoRequest = 1
        coordinator.parent = editor
        coordinator.applyExternalState(to: textView)
        XCTAssertEqual(textView.text, "한글🙂")
    }

    func testTextRuleEngineInsertsAllSmartPairsAtCaret() {
        let cases: [(String, String)] = [
            ("'", "''"),
            ("\"", "\"\""),
            ("[", "[]"),
            ("(", "()"),
            ("{", "{}")
        ]

        for (input, expectedReplacement) in cases {
            let result = TextRuleEngine.evaluate(
                textRuleRequest(text: "가🙂나", location: 1, replacement: input)
            )

            XCTAssertTrue(result.handled, input)
            XCTAssertEqual(result.edit?.replacement, expectedReplacement, input)
            XCTAssertEqual(result.edit?.range, TextCursorState(location: 1, selectionLength: 0))
            XCTAssertEqual(result.selection, TextCursorState(location: 2, selectionLength: 0))
        }

        for (text, location) in [("문서", UInt(0)), ("문서", UInt(2)), ("첫줄\n둘째", UInt(3))] {
            let result = TextRuleEngine.evaluate(
                textRuleRequest(text: text, location: location, replacement: "(")
            )
            XCTAssertTrue(result.handled, "\(text) @ \(location)")
            XCTAssertEqual(result.edit?.range.location, location)
            XCTAssertEqual(result.edit?.replacement, "()")
        }
    }

    @MainActor
    func testTextRuleBridgeUsesBoundedContextAtEndOfLongManuscript() {
        let original = String(repeating: "긴 원고 문장🙂\n", count: 5_000)
        var boundText = original
        var selection = TextCursorState(
            location: UInt(original.utf16.count),
            selectionLength: 0
        )
        let editor = iPadTextEditor(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            documentID: DocumentID(rawValue: UUID()),
            externalVersion: 0,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            focusRequest: 0
        )
        let coordinator = iPadTextEditor.Coordinator(parent: editor)
        let textView = SmartTextView()
        textView.delegate = coordinator
        coordinator.applyExternalState(to: textView)

        let shouldApplySystemEdit = coordinator.textView(
            textView,
            shouldChangeTextIn: textView.selectedRange,
            replacementText: "("
        )

        XCTAssertFalse(shouldApplySystemEdit)
        XCTAssertEqual(boundText, original)
        XCTAssertTrue(textView.text.hasSuffix("()"))
        XCTAssertEqual(selection.selectionLength, 0)
        XCTAssertLessThan(coordinator.lastTextRuleContextUTF16Length, 64)
        XCTAssertGreaterThan(original.utf16.count, coordinator.lastTextRuleContextUTF16Length * 1_000)
    }

    func testTextRuleEngineWrapsUnicodeSelectionWithoutSplittingUTF16() {
        let text = "앞한글🙂뒤"
        let selected = "한글🙂"
        let location = UInt("앞".utf16.count)
        let length = UInt(selected.utf16.count)
        let result = TextRuleEngine.evaluate(
            textRuleRequest(
                text: text,
                location: location,
                selectionLength: length,
                replacement: "["
            )
        )

        XCTAssertEqual(
            result.edit,
            TextEditOperation(
                range: TextCursorState(location: location, selectionLength: length),
                replacement: "[한글🙂]"
            )
        )
        XCTAssertEqual(
            result.selection,
            TextCursorState(location: location + 1, selectionLength: length)
        )
    }

    func testTextRuleEngineSkipsCloserDeletesEmptyPairAndMovesNewlineOutside() {
        let skip = TextRuleEngine.evaluate(
            textRuleRequest(text: "()", location: 1, replacement: ")")
        )
        XCTAssertTrue(skip.handled)
        XCTAssertNil(skip.edit)
        XCTAssertEqual(skip.selection, TextCursorState(location: 2, selectionLength: 0))

        for pair in ["''", "\"\"", "[]", "()", "{}", "「」", "『』"] {
            let deletion = TextRuleEngine.evaluate(
                textRuleRequest(
                    text: "가\(pair)나",
                    location: 2,
                    changeLocation: 1,
                    changeLength: 1,
                    replacement: ""
                )
            )
            XCTAssertEqual(
                deletion.edit,
                TextEditOperation(
                    range: TextCursorState(location: 1, selectionLength: 2),
                    replacement: ""
                ),
                pair
            )
            XCTAssertEqual(
                deletion.selection,
                TextCursorState(location: 1, selectionLength: 0),
                pair
            )
        }

        let newline = TextRuleEngine.evaluate(
            textRuleRequest(text: "(내용)", location: 3, replacement: "\n")
        )
        XCTAssertEqual(
            newline.edit,
            TextEditOperation(
                range: TextCursorState(location: 4, selectionLength: 0),
                replacement: "\n"
            )
        )
        XCTAssertEqual(newline.selection, TextCursorState(location: 5, selectionLength: 0))

        for pair in ["「」", "『』"] {
            let enter = TextRuleEngine.evaluate(
                textRuleRequest(text: pair, location: 1, replacement: "\n")
            )
            XCTAssertEqual(
                enter.edit,
                TextEditOperation(
                    range: TextCursorState(location: 2, selectionLength: 0),
                    replacement: "\n"
                ),
                pair
            )
            XCTAssertEqual(
                enter.selection,
                TextCursorState(location: 3, selectionLength: 0),
                pair
            )
        }
    }

    func testTextRuleEngineBypassesCompositionDisabledSettingAndInvalidUnicodeRange() {
        let composing = TextRuleEngine.evaluate(
            textRuleRequest(text: "한", location: 1, replacement: "(", isComposing: true)
        )
        XCTAssertFalse(composing.handled)

        let disabled = TextRuleEngine.evaluate(
            textRuleRequest(text: "", location: 0, replacement: "(", settings: .disabled)
        )
        XCTAssertFalse(disabled.handled)

        let insideEmojiUTF16 = TextRuleEngine.evaluate(
            textRuleRequest(text: "🙂", location: 1, replacement: "(")
        )
        XCTAssertFalse(insideEmojiUTF16.handled)

        let insideCombiningSequence = TextRuleEngine.evaluate(
            textRuleRequest(text: "e\u{301}", location: 1, replacement: "(")
        )
        XCTAssertFalse(insideCombiningSequence.handled)

        let insideJoinedEmoji = TextRuleEngine.evaluate(
            textRuleRequest(text: "👨‍👩‍👧‍👦", location: 2, replacement: "(")
        )
        XCTAssertFalse(insideJoinedEmoji.handled)

        let pastEnd = TextRuleEngine.evaluate(
            textRuleRequest(text: "끝", location: 20, replacement: "[")
        )
        XCTAssertFalse(pastEnd.handled)

        let multiCharacterPaste = TextRuleEngine.evaluate(
            textRuleRequest(text: "", location: 0, replacement: "()")
        )
        XCTAssertFalse(multiCharacterPaste.handled)
    }

    func testTextRuleEngineHonorsIndependentSmartInputSettings() {
        let pairsOff = TextRuleSettings(
            smartPairsEnabled: false,
            ellipsisConversionEnabled: true,
            specialQuotationShortcutsEnabled: true,
            sceneBreakEnabled: true
        )
        XCTAssertFalse(
            TextRuleEngine.evaluate(
                textRuleRequest(
                    text: "",
                    location: 0,
                    replacement: "(",
                    settings: pairsOff
                )
            ).handled
        )

        let ellipsisOff = TextRuleSettings(
            smartPairsEnabled: true,
            ellipsisConversionEnabled: false,
            specialQuotationShortcutsEnabled: true,
            sceneBreakEnabled: true
        )
        XCTAssertFalse(
            TextRuleEngine.evaluate(
                textRuleRequest(
                    text: "..",
                    location: 2,
                    replacement: ".",
                    settings: ellipsisOff
                )
            ).handled
        )

        let quotationsOff = TextRuleSettings(
            smartPairsEnabled: true,
            ellipsisConversionEnabled: true,
            specialQuotationShortcutsEnabled: false,
            sceneBreakEnabled: true
        )
        XCTAssertFalse(
            TextRuleEngine.evaluate(
                textRuleRequest(
                    text: "ㄴ",
                    location: 1,
                    replacement: "ㄴ",
                    settings: quotationsOff
                )
            ).handled
        )
        XCTAssertFalse(
            TextRuleEngine.evaluateCompositionCompletion(
                TextRuleCompositionRequest(
                    text: "ㄴㄴ",
                    selection: TextCursorState(location: 2, selectionLength: 0),
                    confirmedRange: TextCursorState(location: 0, selectionLength: 2),
                    settings: quotationsOff
                )
            ).handled
        )

        let sceneBreakOff = TextRuleSettings(
            smartPairsEnabled: true,
            ellipsisConversionEnabled: true,
            specialQuotationShortcutsEnabled: true,
            sceneBreakEnabled: false
        )
        XCTAssertFalse(
            TextRuleEngine.evaluate(
                textRuleRequest(
                    text: "",
                    location: 0,
                    replacement: "*",
                    settings: sceneBreakOff
                )
            ).handled
        )

        XCTAssertTrue(
            TextRuleEngine.evaluate(
                textRuleRequest(
                    text: "..",
                    location: 2,
                    replacement: ".",
                    settings: pairsOff
                )
            ).handled
        )
    }

    func testCompositionTrackerReturnsOnlyTheLatestConfirmedIMEInterval() {
        var tracker = CompositionSessionTracker()

        XCTAssertNil(
            tracker.update(
                markedRange: TextCursorState(location: 4, selectionLength: 1),
                selection: TextCursorState(location: 5, selectionLength: 0)
            )
        )
        XCTAssertNil(
            tracker.update(
                markedRange: TextCursorState(location: 5, selectionLength: 1),
                selection: TextCursorState(location: 6, selectionLength: 0)
            )
        )
        XCTAssertEqual(
            tracker.update(
                markedRange: nil,
                selection: TextCursorState(location: 6, selectionLength: 0)
            ),
            TextCursorState(location: 4, selectionLength: 2)
        )
        XCTAssertNil(
            tracker.update(
                markedRange: nil,
                selection: TextCursorState(location: 6, selectionLength: 0)
            )
        )
    }

    func testTextRuleEngineConvertsConfirmedKoreanTriggersToQuotationPairs() {
        let cases = [
            (text: "앞ㄴㄴ", location: UInt(1), trigger: "ㄴㄴ", replacement: "「」"),
            (text: "🙂ㄱㄱ", location: UInt(2), trigger: "ㄱㄱ", replacement: "『』")
        ]

        for item in cases {
            let triggerLength = UInt(item.trigger.utf16.count)
            let selection = TextCursorState(
                location: item.location + triggerLength,
                selectionLength: 0
            )
            let result = TextRuleEngine.evaluateCompositionCompletion(
                TextRuleCompositionRequest(
                    text: item.text,
                    selection: selection,
                    confirmedRange: TextCursorState(
                        location: item.location,
                        selectionLength: triggerLength
                    ),
                    settings: .enabled
                )
            )

            XCTAssertEqual(
                result.edit,
                TextEditOperation(
                    range: TextCursorState(
                        location: item.location,
                        selectionLength: triggerLength
                    ),
                    replacement: item.replacement
                )
            )
            XCTAssertEqual(
                result.selection,
                TextCursorState(location: item.location + 1, selectionLength: 0)
            )
        }

        let disabled = TextRuleEngine.evaluateCompositionCompletion(
            TextRuleCompositionRequest(
                text: "ㄴㄴ",
                selection: TextCursorState(location: 2, selectionLength: 0),
                confirmedRange: TextCursorState(location: 0, selectionLength: 2),
                settings: .disabled
            )
        )
        XCTAssertFalse(disabled.handled)

        let existingTextOutsideConfirmedRange = TextRuleEngine.evaluateCompositionCompletion(
            TextRuleCompositionRequest(
                text: "ㄴㄴ",
                selection: TextCursorState(location: 2, selectionLength: 0),
                confirmedRange: TextCursorState(location: 1, selectionLength: 1),
                settings: .enabled
            )
        )
        XCTAssertFalse(existingTextOutsideConfirmedRange.handled)
    }

    func testDirectKoreanShortcutsAndEllipsis() {
        let cases = [
            (text: "문장ㄴ", input: "ㄴ", replacement: "「」", location: UInt(2)),
            (text: "🙂ㄱ", input: "ㄱ", replacement: "『』", location: UInt(2)),
            (text: "문장..", input: ".", replacement: "⋯", location: UInt(2))
        ]

        for item in cases {
            let cursor = UInt(item.text.utf16.count)
            let result = TextRuleEngine.evaluate(
                textRuleRequest(
                    text: item.text,
                    location: cursor,
                    replacement: item.input
                )
            )
            XCTAssertEqual(result.edit?.replacement, item.replacement, item.input)
            XCTAssertEqual(result.edit?.range.location, item.location, item.input)
            XCTAssertEqual(result.selection.location, item.location + 1, item.input)
        }

        let batchedEllipsis = TextRuleEngine.evaluate(
            textRuleRequest(text: "문장", location: 2, replacement: "...")
        )
        XCTAssertEqual(batchedEllipsis.edit?.replacement, "⋯")
        XCTAssertEqual(batchedEllipsis.selection.location, 3)

        for bypass in [
            textRuleRequest(text: "ㄴ", location: 1, replacement: "ㄴ", settings: .disabled),
            textRuleRequest(text: "ㄴ", location: 1, replacement: "ㄴ", isComposing: true),
            textRuleRequest(text: "..", location: 2, replacement: ".", isPaste: true)
        ] {
            XCTAssertFalse(TextRuleEngine.evaluate(bypass).handled)
        }
    }

    func testTextRuleEngineInsertsAndDeletesWholeSceneBreak() {
        let prefix = "소설내용."
        let insertionLocation = UInt(prefix.utf16.count)
        let insertion = TextRuleEngine.evaluate(
            textRuleRequest(text: prefix, location: insertionLocation, replacement: "*")
        )
        XCTAssertEqual(
            insertion.edit,
            TextEditOperation(
                range: TextCursorState(location: insertionLocation, selectionLength: 0),
                replacement: "\n\n * * *\n\n"
            )
        )
        XCTAssertEqual(
            insertion.selection.location,
            insertionLocation + UInt(TextRuleEngine.sceneBreak.utf16.count)
        )

        let fullText = prefix + TextRuleEngine.sceneBreak + "다음내용."
        let afterScene = insertionLocation + UInt(TextRuleEngine.sceneBreak.utf16.count)
        let backspace = TextRuleEngine.evaluate(
            textRuleRequest(
                text: fullText,
                location: afterScene,
                changeLocation: afterScene - 1,
                changeLength: 1,
                replacement: ""
            )
        )
        XCTAssertEqual(
            backspace.edit,
            TextEditOperation(
                range: TextCursorState(
                    location: insertionLocation,
                    selectionLength: UInt(TextRuleEngine.sceneBreak.utf16.count)
                ),
                replacement: ""
            )
        )

        let delete = TextRuleEngine.evaluate(
            textRuleRequest(
                text: fullText,
                location: insertionLocation,
                changeLocation: insertionLocation,
                changeLength: 1,
                replacement: ""
            )
        )
        XCTAssertEqual(delete.edit, backspace.edit)

        let pasted = TextRuleEngine.evaluate(
            textRuleRequest(
                text: prefix,
                location: insertionLocation,
                replacement: "*",
                isPaste: true
            )
        )
        XCTAssertFalse(pasted.handled)
    }

    @MainActor
    func testSceneBreakAndKoreanQuotationTransformAreSingleUndoUnits() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let controller = UIViewController()
        let textView = SmartTextView(frame: window.bounds)
        controller.view.addSubview(textView)
        window.rootViewController = controller
        window.makeKeyAndVisible()

        textView.applyExternalText(
            "내용",
            selection: TextCursorState(location: 2, selectionLength: 0),
            clearsUndoHistory: true
        )
        let sceneResult = TextRuleEngine.evaluate(
            textRuleRequest(text: "내용", location: 2, replacement: "*")
        )
        textView.applyTextRuleResult(sceneResult)
        XCTAssertEqual(textView.text, "내용\n\n * * *\n\n")
        textView.performUndo()
        XCTAssertEqual(textView.text, "내용")
        textView.performRedo()
        XCTAssertEqual(textView.text, "내용\n\n * * *\n\n")

        let afterScene = UInt(textView.text.utf16.count)
        let deleteSceneResult = TextRuleEngine.evaluate(
            textRuleRequest(
                text: textView.text,
                location: afterScene,
                changeLocation: afterScene - 1,
                changeLength: 1,
                replacement: ""
            )
        )
        textView.applyTextRuleResult(deleteSceneResult)
        XCTAssertEqual(textView.text, "내용")
        textView.performUndo()
        XCTAssertEqual(textView.text, "내용\n\n * * *\n\n")

        textView.applyExternalText(
            "ㄴㄴ",
            selection: TextCursorState(location: 2, selectionLength: 0),
            clearsUndoHistory: true
        )
        let quotationResult = TextRuleEngine.evaluateCompositionCompletion(
            TextRuleCompositionRequest(
                text: "ㄴㄴ",
                selection: TextCursorState(location: 2, selectionLength: 0),
                confirmedRange: TextCursorState(location: 0, selectionLength: 2),
                settings: .enabled
            )
        )
        textView.applyTextRuleResult(quotationResult)
        XCTAssertEqual(textView.text, "「」")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 1, length: 0))
        textView.performUndo()
        XCTAssertEqual(textView.text, "ㄴㄴ")
        textView.performRedo()
        XCTAssertEqual(textView.text, "「」")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 1, length: 0))

        let enterResult = TextRuleEngine.evaluate(
            textRuleRequest(text: "「」", location: 1, replacement: "\n")
        )
        textView.applyTextRuleResult(enterResult)
        XCTAssertEqual(textView.text, "「」\n")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 3, length: 0))
        textView.performUndo()
        XCTAssertEqual(textView.text, "「」")

        textView.applyExternalText(
            "『』",
            selection: TextCursorState(location: 1, selectionLength: 0),
            clearsUndoHistory: true
        )
        let deletePairResult = TextRuleEngine.evaluate(
            textRuleRequest(
                text: "『』",
                location: 1,
                changeLocation: 0,
                changeLength: 1,
                replacement: ""
            )
        )
        textView.applyTextRuleResult(deletePairResult)
        XCTAssertEqual(textView.text, "")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 0))
        textView.performUndo()
        XCTAssertEqual(textView.text, "『』")
    }

    @MainActor
    func testSmartPairEditIsOneUndoAndRedoUnit() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let controller = UIViewController()
        let textView = SmartTextView(frame: window.bounds)
        controller.view.addSubview(textView)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        textView.applyExternalText(
            "문장",
            selection: TextCursorState(location: 2, selectionLength: 0),
            clearsUndoHistory: true
        )
        let result = TextRuleEngine.evaluate(
            textRuleRequest(text: "문장", location: 2, replacement: "(")
        )

        textView.applyTextRuleResult(result)
        XCTAssertEqual(textView.text, "문장()")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 3, length: 0))
        XCTAssertTrue(try XCTUnwrap(textView.undoManager).canUndo)

        textView.performUndo()
        XCTAssertEqual(textView.text, "문장")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 2, length: 0))

        textView.performRedo()
        XCTAssertEqual(textView.text, "문장()")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 3, length: 0))
    }

    @MainActor
    func testFirstSmartPairInEmptyDocumentKeepsEditorAppearance() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        let controller = UIViewController()
        let textView = SmartTextView(frame: window.bounds)
        controller.view.addSubview(textView)
        window.rootViewController = controller
        window.makeKeyAndVisible()

        let appearance = EditorAppearanceSettings(
            fontFamily: .malgunGothicBold,
            fontSize: 24,
            lineSpacing: 12,
            horizontalInset: 32,
            verticalInset: 28,
            typewriterScrolling: false
        )
        textView.applyExternalText(
            "",
            selection: .start,
            clearsUndoHistory: true
        )
        textView.applyAppearance(appearance)
        let expectedFont = try XCTUnwrap(textView.typingAttributes[.font] as? UIFont)
        let expectedParagraph = try XCTUnwrap(
            textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle
        )
        let result = TextRuleEngine.evaluate(
            textRuleRequest(text: "", location: 0, replacement: "(")
        )

        textView.applyTextRuleResult(result)

        XCTAssertEqual(textView.text, "()")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 1, length: 0))
        for location in 0..<textView.textStorage.length {
            let font = try XCTUnwrap(
                textView.textStorage.attribute(.font, at: location, effectiveRange: nil)
                    as? UIFont
            )
            let paragraph = try XCTUnwrap(
                textView.textStorage.attribute(
                    .paragraphStyle,
                    at: location,
                    effectiveRange: nil
                ) as? NSParagraphStyle
            )
            XCTAssertEqual(font.fontName, expectedFont.fontName)
            XCTAssertEqual(font.pointSize, expectedFont.pointSize, accuracy: 0.01)
            XCTAssertEqual(
                paragraph.lineSpacing,
                expectedParagraph.lineSpacing,
                accuracy: 0.01
            )
        }
    }

    @MainActor
    func testEditorSessionLoadsUTF8AndRestoresUnsavedDraftInMemory() async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(named: "편집 세션")
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        let volume = try await environment.binderCommands.addNewVolume(projectID: project.id)
        let loadedDocument = try await environment.documentRepository.document(
            id: volume.documentToOpenID
        )
        let document = try XCTUnwrap(loadedDocument)
        _ = try await environment.localDocumentStore.save(
            DocumentSaveRequest(
                projectID: project.id,
                documentID: document.id,
                relativePath: document.relativePath,
                text: "첫 문장 한글🙂",
                generation: 1
            )
        )
        let textNode = BinderNode(
            id: document.id,
            projectID: project.id,
            kind: .text,
            relativePath: document.relativePath,
            displayName: "001화",
            fixedCategory: nil,
            userOrder: document.userOrder,
            contentState: .written,
            isExpanded: false
        )
        let roots = try await environment.binderRepository.rootNodes(in: project.id)
        let manuscript = try XCTUnwrap(roots.first { $0.fixedCategory == .manuscript })
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            workspaceStateRepository: environment.workspaceStateRepository
        )

        await model.select(textNode)
        XCTAssertEqual(model.text, "첫 문장 한글🙂")
        XCTAssertEqual(model.currentDocumentID, document.id)
        XCTAssertEqual(model.statistics.characterCount, "첫 문장 한글🙂".count)

        model.updateText("저장 전 초안 👩‍💻")
        let calculationCount = model.statisticsCalculationCount
        model.updateText("저장 전 초안 👩‍💻")
        XCTAssertEqual(model.statisticsCalculationCount, calculationCount)
        model.cursor = TextCursorState(location: 4, selectionLength: 2)
        await model.select(manuscript)
        let persistedCursor = try await environment.workspaceStateRepository.cursor(
            for: document.id
        )
        XCTAssertEqual(
            persistedCursor,
            TextCursorState(location: 4, selectionLength: 2)
        )
        await model.select(textNode)

        XCTAssertEqual(model.text, "저장 전 초안 👩‍💻")
        XCTAssertEqual(model.cursor, TextCursorState(location: 4, selectionLength: 2))
    }

    @MainActor
    func testTrashedDocumentOpensReadOnlyWithoutSavingMutations()
        async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(
            named: "휴지통 읽기 전용"
        )
        let roots = try await environment.binderRepository.rootNodes(in: project.id)
        let notes = try XCTUnwrap(
            roots.first { $0.fixedCategory == .notes }
        )
        let created = try await environment.binderCommands.create(
            kind: .text,
            named: "버려진 문서",
            in: notes.id,
            projectID: project.id
        )
        let loadedActiveDocument = try await environment.documentRepository
            .document(id: created.affectedDocumentID)
        let activeDocument = try XCTUnwrap(
            loadedActiveDocument
        )
        _ = try await environment.localDocumentStore.save(
            DocumentSaveRequest(
                projectID: project.id,
                documentID: activeDocument.id,
                relativePath: activeDocument.relativePath,
                text: "읽기만 할 본문\n두 번째 줄",
                generation: 1
            )
        )
        _ = try await environment.binderCommands.moveToTrash(
            documentID: activeDocument.id,
            projectID: project.id
        )
        let loadedTrashedDocument = try await environment.documentRepository
            .document(id: activeDocument.id)
        let trashedDocument = try XCTUnwrap(
            loadedTrashedDocument
        )
        let node = BinderNode(
            id: trashedDocument.id,
            projectID: project.id,
            kind: .text,
            relativePath: trashedDocument.relativePath,
            displayName: "버려진 문서",
            fixedCategory: nil,
            userOrder: trashedDocument.userOrder,
            contentState: .written,
            isExpanded: false
        )
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            workspaceStateRepository: environment.workspaceStateRepository
        )

        await model.select(node)

        XCTAssertTrue(model.isReadOnly)
        XCTAssertEqual(model.currentText, "읽기만 할 본문\n두 번째 줄")
        XCTAssertEqual(model.focusRequest, 0)
        model.updateText("바꾸면 안 됨")
        XCTAssertEqual(model.currentText, "읽기만 할 본문\n두 번째 줄")
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertNil(
            model.automaticRebaseSnapshot(
                documentID: trashedDocument.id
            )
        )
        let didSave = await model.saveNow()
        XCTAssertTrue(didSave)
        let storedText = try await environment.localDocumentStore.loadText(
            for: trashedDocument
        )
        XCTAssertEqual(
            storedText,
            "읽기만 할 본문\n두 번째 줄"
        )

        _ = try await environment.binderCommands.restoreFromTrash(
            documentID: trashedDocument.id,
            toFolderID: nil,
            projectID: project.id
        )
        let loadedRestoredDocument = try await environment.documentRepository
            .document(id: trashedDocument.id)
        let restoredDocument = try XCTUnwrap(loadedRestoredDocument)
        let restoredNode = BinderNode(
            id: restoredDocument.id,
            projectID: project.id,
            kind: .text,
            relativePath: restoredDocument.relativePath,
            displayName: "버려진 문서",
            fixedCategory: nil,
            userOrder: restoredDocument.userOrder,
            contentState: .written,
            isExpanded: false
        )

        await model.select(restoredNode)

        XCTAssertFalse(model.isReadOnly)
        model.updateText("복원 후에는 편집 가능")
        XCTAssertTrue(model.hasUnsavedChanges)
        let didSaveRestoredDocument = await model.saveNow()
        XCTAssertTrue(didSaveRestoredDocument)
        let restoredText = try await environment.localDocumentStore.loadText(
            for: restoredDocument
        )
        XCTAssertEqual(
            restoredText,
            "복원 후에는 편집 가능"
        )
    }

    @MainActor
    func testReadOnlyNativeEditorDisablesEditingButKeepsScrolling() {
        let textView = SmartTextView()
        let editor = iPadTextEditor(
            text: .constant(""),
            documentID: DocumentID(rawValue: UUID()),
            externalVersion: 1,
            selection: .constant(.start),
            focusRequest: 1,
            isActive: true,
            isReadOnly: true,
            placeholder: "휴지통 문서는 수정 할 수 없습니다."
        )
        let coordinator = editor.makeCoordinator()
        textView.delegate = coordinator

        coordinator.applyExternalState(to: textView)

        XCTAssertFalse(textView.isEditable)
        XCTAssertFalse(textView.isSelectable)
        XCTAssertTrue(textView.isScrollEnabled)
        XCTAssertTrue(textView.isUserInteractionEnabled)
        XCTAssertEqual(textView.text, "")
        XCTAssertEqual(
            textView.placeholderText,
            "휴지통 문서는 수정 할 수 없습니다."
        )
        XCTAssertEqual(textView.accessibilityValue, "읽기 전용")
    }

    @MainActor
    func testEditorSessionManualSaveAtomicallyWritesCurrentUTF8Text() async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(named: "명령 저장")
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        let volume = try await environment.binderCommands.addNewVolume(projectID: project.id)
        let loadedDocument = try await environment.documentRepository.document(
            id: volume.documentToOpenID
        )
        let document = try XCTUnwrap(loadedDocument)
        let node = BinderNode(
            id: document.id,
            projectID: project.id,
            kind: .text,
            relativePath: document.relativePath,
            displayName: "001화",
            fixedCategory: nil,
            userOrder: document.userOrder,
            contentState: .empty,
            isExpanded: false
        )
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            workspaceStateRepository: environment.workspaceStateRepository
        )

        await model.select(node)
        model.updateText("외장 키보드 저장 한글🙂")

        let didSave = await model.saveNow()
        XCTAssertTrue(didSave)
        let savedText = try await environment.localDocumentStore.loadText(for: document)
        XCTAssertEqual(savedText, "외장 키보드 저장 한글🙂")
        guard case .saved = model.saveState else {
            return XCTFail("수동 저장 성공 상태여야 합니다.")
        }
    }

    @MainActor
    func testEditorSessionDefersDurableHandoffUntilIMECompositionEnds()
        async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(
            named: "IME queue 경계"
        )
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        let volume = try await environment.binderCommands.addNewVolume(
            projectID: project.id
        )
        let loadedDocument = try await environment.documentRepository.document(
            id: volume.documentToOpenID
        )
        let document = try XCTUnwrap(loadedDocument)
        let operationID = UUID()
        let store = ScriptedSyncHandoffDocumentStore(
            underlying: environment.localDocumentStore,
            saveResult: .queued(operationIDs: [operationID])
        )
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: store,
            workspaceStateRepository: environment.workspaceStateRepository,
            autosaveDelay: .seconds(60)
        )
        let node = BinderNode(
            id: document.id,
            projectID: document.projectID,
            kind: .text,
            relativePath: document.relativePath,
            displayName: "001화",
            fixedCategory: nil,
            userOrder: document.userOrder,
            contentState: .empty,
            isExpanded: false
        )
        await model.select(node)
        await model.updateCompositionState(true)
        model.updateText("조합 중간 본문")

        let deferred = await model.saveNow()

        XCTAssertTrue(deferred)
        let saveCountDuringComposition = await store.saveCount()
        XCTAssertEqual(saveCountDuringComposition, 0)
        await model.updateCompositionState(false)
        let saveCountAfterComposition = await store.saveCount()
        XCTAssertEqual(saveCountAfterComposition, 1)
        guard case let .queued(_, operationIDs) = model.syncHandoffState else {
            return XCTFail("조합 확정 뒤 queue 기록 상태여야 합니다.")
        }
        XCTAssertEqual(operationIDs, [operationID])
    }

    @MainActor
    func testEditorSessionKeepsLocalSuccessOnQueueFailureAndRetries()
        async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(
            named: "queue 실패 분리"
        )
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        let volume = try await environment.binderCommands.addNewVolume(
            projectID: project.id
        )
        let loadedDocument = try await environment.documentRepository.document(
            id: volume.documentToOpenID
        )
        let document = try XCTUnwrap(loadedDocument)
        let operationID = UUID()
        let store = ScriptedSyncHandoffDocumentStore(
            underlying: environment.localDocumentStore,
            saveResult: .localSavedButNotQueued(reason: "injected"),
            retryResults: [.queued(operationIDs: [operationID])]
        )
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: store,
            workspaceStateRepository: environment.workspaceStateRepository,
            autosaveDelay: .seconds(60)
        )
        let node = BinderNode(
            id: document.id,
            projectID: document.projectID,
            kind: .text,
            relativePath: document.relativePath,
            displayName: "001화",
            fixedCategory: nil,
            userOrder: document.userOrder,
            contentState: .empty,
            isExpanded: false
        )
        await model.select(node)
        model.updateText("queue 실패와 무관하게 보존될 원고🙂")

        let savedLocally = await model.saveNow()

        XCTAssertTrue(savedLocally)
        guard case .saved = model.saveState else {
            return XCTFail("로컬 저장은 성공 상태여야 합니다.")
        }
        guard case .failed = model.syncHandoffState else {
            return XCTFail("queue 기록 실패는 별도 상태여야 합니다.")
        }
        let diskText = try await environment.localDocumentStore.loadText(
            for: document
        )
        XCTAssertEqual(diskText, "queue 실패와 무관하게 보존될 원고🙂")

        let retried = await model.saveNow()

        XCTAssertTrue(retried)
        let retryCount = await store.retryCount()
        XCTAssertEqual(retryCount, 1)
        guard case let .queued(_, operationIDs) = model.syncHandoffState else {
            return XCTFail("동일 원고의 queue 재기록이 성공해야 합니다.")
        }
        XCTAssertEqual(operationIDs, [operationID])
    }

    @MainActor
    func testEditorSessionKeepsOversizedServerResultSeparateFromLocalSave()
        async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(
            named: "서버 크기 제한"
        )
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        let volume = try await environment.binderCommands.addNewVolume(
            projectID: project.id
        )
        let loadedDocument = try await environment.documentRepository.document(
            id: volume.documentToOpenID
        )
        let document = try XCTUnwrap(loadedDocument)
        let store = ScriptedSyncHandoffDocumentStore(
            underlying: environment.localDocumentStore,
            saveResult: .serverSizeLimitExceeded(
                byteCount: 10_485_761,
                limit: 10_485_760
            )
        )
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: store,
            workspaceStateRepository: environment.workspaceStateRepository,
            autosaveDelay: .seconds(60)
        )
        await model.select(
            BinderNode(
                id: document.id,
                projectID: document.projectID,
                kind: .text,
                relativePath: document.relativePath,
                displayName: "001화",
                fixedCategory: nil,
                userOrder: document.userOrder,
                contentState: .empty,
                isExpanded: false
            )
        )
        model.updateText("로컬에는 저장되는 본문")

        let saved = await model.saveNow()
        XCTAssertTrue(saved)
        guard case .saved = model.saveState else {
            return XCTFail("서버 제한은 로컬 저장 실패가 아니어야 합니다.")
        }
        guard case let .serverSizeLimitExceeded(
            generation,
            byteCount,
            limit
        ) = model.syncHandoffState else {
            return XCTFail("서버 크기 제한 상태여야 합니다.")
        }
        XCTAssertGreaterThan(generation, 0)
        XCTAssertEqual(byteCount, 10_485_761)
        XCTAssertEqual(limit, 10_485_760)
    }

    @MainActor
    func testEditorSessionReplaysPendingHandoffWhenDocumentOpens()
        async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(
            named: "재실행 handoff"
        )
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        let volume = try await environment.binderCommands.addNewVolume(
            projectID: project.id
        )
        let loadedDocument = try await environment.documentRepository.document(
            id: volume.documentToOpenID
        )
        let document = try XCTUnwrap(loadedDocument)
        let operationID = UUID()
        let store = ScriptedSyncHandoffDocumentStore(
            underlying: environment.localDocumentStore,
            saveResult: .localOnly,
            retryResults: [.queued(operationIDs: [operationID])],
            hasPendingHandoff: true
        )
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: store,
            workspaceStateRepository: environment.workspaceStateRepository
        )
        let node = BinderNode(
            id: document.id,
            projectID: document.projectID,
            kind: .text,
            relativePath: document.relativePath,
            displayName: "001화",
            fixedCategory: nil,
            userOrder: document.userOrder,
            contentState: .empty,
            isExpanded: false
        )

        await model.select(node)

        let retryCount = await store.retryCount()
        XCTAssertEqual(retryCount, 1)
        guard case let .queued(_, operationIDs) = model.syncHandoffState else {
            return XCTFail("문서를 열 때 남은 handoff를 queue에 복구해야 합니다.")
        }
        XCTAssertEqual(operationIDs, [operationID])
    }

    @MainActor
    func testEditorSessionDebouncesAutosaveAndFlushesBeforeChapterTransition() async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(named: "자동 저장")
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        _ = try await environment.binderCommands.addNewVolume(projectID: project.id)
        let documents = try await environment.documentRepository.documents(in: project.id)
            .filter { $0.kind == .text && $0.relativePath.rawValue.contains("/원고/") }
            .sorted { $0.userOrder < $1.userOrder }
        let first = try XCTUnwrap(documents.first)
        let second = try XCTUnwrap(documents.dropFirst().first)
        func node(_ document: DocumentNode) -> BinderNode {
            BinderNode(
                id: document.id,
                projectID: document.projectID,
                kind: .text,
                relativePath: document.relativePath,
                displayName: document.relativePath.rawValue,
                fixedCategory: nil,
                userOrder: document.userOrder,
                contentState: .empty,
                isExpanded: false
            )
        }
        let sleepProbe = AutosaveSleepProbe()
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            workspaceStateRepository: environment.workspaceStateRepository,
            autosaveSleep: { duration in
                await sleepProbe.record(duration)
            }
        )

        await model.select(node(first))
        model.updateText("연속 입력 1")
        model.updateText("연속 입력 최종🙂")

        var autosavedText = ""
        for _ in 0..<200 {
            autosavedText = try await environment.localDocumentStore.loadText(for: first)
            if autosavedText == "연속 입력 최종🙂" { break }
            await Task.yield()
        }
        XCTAssertEqual(autosavedText, "연속 입력 최종🙂")
        let recordedDelays = await sleepProbe.recordedDelays()
        XCTAssertEqual(recordedDelays.last, AutosaveDebouncer.defaultDelay)

        model.updateAutosaveDelay(.milliseconds(1_500))
        model.updateText("변경된 대기시간으로 저장")
        for _ in 0..<200 {
            let latestDelay = await sleepProbe.recordedDelays().last
            if latestDelay == .milliseconds(1_500) {
                break
            }
            await Task.yield()
        }
        let updatedDelay = await sleepProbe.recordedDelays().last
        XCTAssertEqual(
            updatedDelay,
            .milliseconds(1_500)
        )

        model.updateText("화 전환 직전 최신 원고")
        await model.select(node(second))
        XCTAssertEqual(model.currentDocumentID, second.id)
        let flushedText = try await environment.localDocumentStore.loadText(for: first)
        XCTAssertEqual(flushedText, "화 전환 직전 최신 원고")
    }

    func testAutosaveDelaySettingDefaultsCorruptStoredValue() {
        XCTAssertEqual(AutosaveDelaySetting.normalized(-1), 800)
        XCTAssertEqual(AutosaveDelaySetting.normalized(801), 800)
        XCTAssertEqual(AutosaveDelaySetting.normalized(500), 500)
        XCTAssertEqual(AutosaveDelaySetting.normalized(3_000), 3_000)
    }

    @MainActor
    func testEditorSessionBlocksChapterTransitionAfterLocalSaveFailureAndRetries() async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(named: "저장 실패 전환 차단")
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        _ = try await environment.binderCommands.addNewVolume(projectID: project.id)
        let documents = try await environment.documentRepository.documents(in: project.id)
            .filter { $0.kind == .text && $0.relativePath.rawValue.contains("/원고/") }
            .sorted { $0.userOrder < $1.userOrder }
        let first = try XCTUnwrap(documents.first)
        let second = try XCTUnwrap(documents.dropFirst().first)
        func node(_ document: DocumentNode) -> BinderNode {
            BinderNode(
                id: document.id,
                projectID: document.projectID,
                kind: .text,
                relativePath: document.relativePath,
                displayName: document.relativePath.rawValue,
                fixedCategory: nil,
                userOrder: document.userOrder,
                contentState: .empty,
                isExpanded: false
            )
        }
        let store = ControllableFailingDocumentStore(
            underlying: environment.localDocumentStore
        )
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: store,
            workspaceStateRepository: environment.workspaceStateRepository,
            autosaveDelay: .seconds(60)
        )

        await model.select(node(first))
        model.updateText("저장 실패해도 유실되면 안 되는 최신 원고🙂")
        await store.setSaveFailureEnabled(true)
        await model.select(node(second))

        XCTAssertEqual(model.currentDocumentID, first.id)
        XCTAssertEqual(model.text, "저장 실패해도 유실되면 안 되는 최신 원고🙂")
        guard case .failed = model.saveState else {
            return XCTFail("저장 실패 상태여야 합니다.")
        }

        await store.setSaveFailureEnabled(false)
        let didRetrySave = await model.saveNow()
        XCTAssertTrue(didRetrySave)
        await model.select(node(second))
        XCTAssertEqual(model.currentDocumentID, second.id)
        let retriedText = try await environment.localDocumentStore.loadText(for: first)
        XCTAssertEqual(
            retriedText,
            "저장 실패해도 유실되면 안 되는 최신 원고🙂"
        )
    }

    @MainActor
    func testChapterTransitionWaitsForTextEnteredDuringSlowSave() async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(named: "느린 저장 중 입력")
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        _ = try await environment.binderCommands.addNewVolume(projectID: project.id)
        let documents = try await environment.documentRepository.documents(in: project.id)
            .filter { $0.kind == .text && $0.relativePath.rawValue.contains("/원고/") }
            .sorted { $0.userOrder < $1.userOrder }
        let first = try XCTUnwrap(documents.first)
        let second = try XCTUnwrap(documents.dropFirst().first)
        func node(_ document: DocumentNode) -> BinderNode {
            BinderNode(
                id: document.id,
                projectID: document.projectID,
                kind: .text,
                relativePath: document.relativePath,
                displayName: document.relativePath.rawValue,
                fixedCategory: nil,
                userOrder: document.userOrder,
                contentState: .empty,
                isExpanded: false
            )
        }
        let store = FirstSaveDelayingDocumentStore(
            underlying: environment.localDocumentStore
        )
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: store,
            workspaceStateRepository: environment.workspaceStateRepository,
            autosaveDelay: .seconds(60)
        )

        await model.select(node(first))
        model.updateText("첫 스냅샷")
        let transition = Task { @MainActor in
            await model.select(node(second))
        }
        await store.waitUntilFirstSaveStarts()
        model.updateText("느린 저장 중에 추가한 최신 문장🙂")
        await store.releaseFirstSave()
        await transition.value

        XCTAssertEqual(model.currentDocumentID, second.id)
        let savedText = try await environment.localDocumentStore.loadText(for: first)
        XCTAssertEqual(savedText, "느린 저장 중에 추가한 최신 문장🙂")
        let saveCount = await store.saveCount()
        XCTAssertEqual(saveCount, 2)
    }

    @MainActor
    func testDualEditorSessionsShareUnsavedDraftWithoutSharingActiveState() async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(named: "듀얼 초안")
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        _ = try await environment.binderCommands.addNewVolume(projectID: project.id)
        let documents = try await environment.documentRepository.documents(in: project.id)
            .filter { $0.kind == .text && $0.relativePath.rawValue.contains("/원고/") }
            .sorted { $0.userOrder < $1.userOrder }
        let first = try XCTUnwrap(documents.first)
        let second = try XCTUnwrap(documents.dropFirst().first)

        func node(_ document: DocumentNode) -> BinderNode {
            BinderNode(
                id: document.id,
                projectID: document.projectID,
                kind: .text,
                relativePath: document.relativePath,
                displayName: document.relativePath.rawValue.split(separator: "/").last.map(String.init) ?? "문서",
                fixedCategory: nil,
                userOrder: document.userOrder,
                contentState: .empty,
                isExpanded: false
            )
        }

        let draftStore = EditorDraftStore()
        let left = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            workspaceStateRepository: environment.workspaceStateRepository,
            draftStore: draftStore
        )
        let right = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            workspaceStateRepository: environment.workspaceStateRepository,
            draftStore: draftStore
        )

        await left.select(node(first))
        left.updateText("왼쪽에서 작성한 저장 전 초안🙂")
        left.cursor = TextCursorState(location: 7, selectionLength: 0)
        await left.select(node(second))
        await right.select(node(first))

        XCTAssertEqual(left.currentDocumentID, second.id)
        XCTAssertEqual(right.currentDocumentID, first.id)
        XCTAssertEqual(right.text, "왼쪽에서 작성한 저장 전 초안🙂")
        XCTAssertEqual(right.cursor, TextCursorState(location: 7, selectionLength: 0))
    }

    @MainActor
    func testDualEditorSessionsRestoreTheirOwnCursorForTheSameDocument() async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(named: "듀얼 커서")
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        _ = try await environment.binderCommands.addNewVolume(projectID: project.id)
        let documents = try await environment.documentRepository.documents(in: project.id)
            .filter { $0.kind == .text && $0.relativePath.rawValue.contains("/원고/") }
            .sorted { $0.userOrder < $1.userOrder }
        let first = try XCTUnwrap(documents.first)
        let second = try XCTUnwrap(documents.dropFirst().first)

        func node(_ document: DocumentNode) -> BinderNode {
            BinderNode(
                id: document.id,
                projectID: document.projectID,
                kind: .text,
                relativePath: document.relativePath,
                displayName: document.relativePath.rawValue,
                fixedCategory: nil,
                userOrder: document.userOrder,
                contentState: .empty,
                isExpanded: false
            )
        }

        let left = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            workspaceStateRepository: environment.workspaceStateRepository
        )
        let right = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            workspaceStateRepository: environment.workspaceStateRepository
        )

        await left.select(node(first))
        await right.select(node(first))
        left.updateCursor(TextCursorState(location: 500, selectionLength: 0))
        right.updateCursor(TextCursorState(location: 1_255, selectionLength: 0))

        await left.select(node(second))
        let rightDidPersist = await right.persistSessionState()
        XCTAssertTrue(rightDidPersist)
        await left.select(node(first))

        XCTAssertEqual(left.cursor, TextCursorState(location: 500, selectionLength: 0))
        XCTAssertEqual(right.cursor, TextCursorState(location: 1_255, selectionLength: 0))
    }

    @MainActor
    func testWorkspaceRepositoryAllowsSameDocumentInBothPanes() async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(named: "듀얼 잠금")
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        let volume = try await environment.binderCommands.addNewVolume(projectID: project.id)
        let duplicatePane = EditorPaneState(
            documentID: volume.documentToOpenID,
            cursor: .start
        )

        try await environment.workspaceStateRepository.saveEditorState(
            EditorWorkspaceState(
                projectID: project.id,
                left: duplicatePane,
                right: duplicatePane,
                activePane: .right
            )
        )
        let restored = try await environment.workspaceStateRepository.editorState(for: project.id)
        XCTAssertEqual(restored.left.documentID, volume.documentToOpenID)
        XCTAssertEqual(restored.right?.documentID, volume.documentToOpenID)
    }

    @MainActor
    func testRemoteSnapshotUpdatesOnlyCleanNonComposingEditor()
        async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(
            named: "snapshot editor"
        )
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        let volume = try await environment.binderCommands.addNewVolume(
            projectID: project.id
        )
        let loaded = try await environment.documentRepository.document(
            id: volume.documentToOpenID
        )
        let document = try XCTUnwrap(loaded)
        let node = BinderNode(
            id: document.id,
            projectID: project.id,
            kind: .text,
            relativePath: document.relativePath,
            displayName: "001화",
            fixedCategory: nil,
            userOrder: document.userOrder,
            contentState: .empty,
            isExpanded: false
        )
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            workspaceStateRepository: environment.workspaceStateRepository
        )
        await model.select(node)

        XCTAssertTrue(
            model.applyRemoteSnapshotIfClean(
                documentID: document.id,
                content: "서버 clean",
                relativePath: "메인/원고/서버 제목.txt"
            )
        )
        XCTAssertEqual(model.currentText, "서버 clean")
        XCTAssertEqual(model.selectedDisplayName, "서버 제목")
        XCTAssertFalse(model.hasUnsavedChanges)

        model.updateText("로컬 dirty")
        XCTAssertFalse(
            model.applyRemoteSnapshotIfClean(
                documentID: document.id,
                content: "덮어쓰면 안 됨"
            )
        )
        XCTAssertEqual(model.currentText, "로컬 dirty")

        let saved = await model.saveNow()
        XCTAssertTrue(saved)
        await model.updateCompositionState(true)
        XCTAssertFalse(
            model.applyRemoteSnapshotIfClean(
                documentID: document.id,
                content: "조합 중 덮어쓰면 안 됨"
            )
        )
        XCTAssertEqual(model.currentText, "로컬 dirty")
        await model.updateCompositionState(false)
    }

    @MainActor
    func testAutomaticRebaseAppliesOnlyMatchingEditorGeneration()
        async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(
            named: "automatic rebase editor"
        )
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        let volume = try await environment.binderCommands.addNewVolume(
            projectID: project.id
        )
        let loaded = try await environment.documentRepository.document(
            id: volume.documentToOpenID
        )
        let document = try XCTUnwrap(loaded)
        let node = BinderNode(
            id: document.id,
            projectID: project.id,
            kind: .text,
            relativePath: document.relativePath,
            displayName: "001화",
            fixedCategory: nil,
            userOrder: document.userOrder,
            contentState: .empty,
            isExpanded: false
        )
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            workspaceStateRepository: environment.workspaceStateRepository
        )
        await model.select(node)
        model.updateText("로컬 최신\n")
        let expected = try XCTUnwrap(
            model.automaticRebaseSnapshot(documentID: document.id)
        )

        XCTAssertTrue(
            model.applyAutomaticRebase(
                expected: expected,
                mergedContent: "로컬 최신\n서버 비겹침\n"
            )
        )
        XCTAssertEqual(
            model.currentText,
            "로컬 최신\n서버 비겹침\n"
        )
        XCTAssertFalse(model.hasUnsavedChanges)

        model.updateText("병합 중 추가 입력\n")
        XCTAssertFalse(
            model.applyAutomaticRebase(
                expected: expected,
                mergedContent: "오래된 병합 결과\n"
            )
        )
        XCTAssertEqual(model.currentText, "병합 중 추가 입력\n")
    }

    @MainActor
    func testEditorSessionKeepsLatestSelectionPendingUntilCompositionEnds() async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(named: "IME 전환")
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        let volume = try await environment.binderCommands.addNewVolume(projectID: project.id)
        let loadedDocument = try await environment.documentRepository.document(
            id: volume.documentToOpenID
        )
        let document = try XCTUnwrap(loadedDocument)
        let textNode = BinderNode(
            id: document.id,
            projectID: project.id,
            kind: .text,
            relativePath: document.relativePath,
            displayName: "001화",
            fixedCategory: nil,
            userOrder: document.userOrder,
            contentState: .empty,
            isExpanded: false
        )
        let roots = try await environment.binderRepository.rootNodes(in: project.id)
        let manuscript = try XCTUnwrap(roots.first { $0.fixedCategory == .manuscript })
        let characters = try XCTUnwrap(roots.first { $0.fixedCategory == .characters })
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            workspaceStateRepository: environment.workspaceStateRepository
        )

        await model.requestSelection(textNode)
        model.updateText("조합 중 초안")
        await model.updateCompositionState(true)
        let commitRequestBeforeSelection = model.compositionCommitRequest
        await model.requestSelection(manuscript)
        await model.requestSelection(characters)

        XCTAssertEqual(model.currentDocumentID, document.id)
        XCTAssertEqual(model.text, "조합 중 초안")
        XCTAssertEqual(model.pendingDisplayName, characters.displayName)
        XCTAssertGreaterThan(model.compositionCommitRequest, commitRequestBeforeSelection)

        await model.updateCompositionState(false)

        XCTAssertNil(model.currentDocumentID)
        XCTAssertNil(model.pendingDisplayName)
        XCTAssertEqual(model.selectedDisplayName, characters.displayName)

        await model.requestSelection(textNode)
        XCTAssertEqual(model.text, "조합 중 초안")

        model.updateFocusState(true)
        let focusRequestBeforeBackground = model.focusRequest
        await model.updateSceneActivity(false)
        await model.updateSceneActivity(true)
        XCTAssertGreaterThan(model.focusRequest, focusRequestBeforeBackground)
        XCTAssertEqual(model.focusPhase, .restoring)

        await model.updateCompositionState(true)
        await model.updateSceneActivity(false)
        let foregroundCommitRequest = model.compositionCommitRequest
        await model.updateSceneActivity(true)
        XCTAssertGreaterThan(
            model.compositionCommitRequest,
            foregroundCommitRequest
        )
        await model.updateCompositionState(false)

        await model.updateCompositionState(true)
        await model.updateSceneActivity(false)
        await model.requestSelection(manuscript)
        await model.updateCompositionState(false)
        XCTAssertEqual(model.currentDocumentID, document.id)
        XCTAssertEqual(model.pendingDisplayName, manuscript.displayName)

        await model.updateSceneActivity(true)
        XCTAssertNil(model.currentDocumentID)
        XCTAssertNil(model.pendingDisplayName)
        XCTAssertEqual(model.selectedDisplayName, manuscript.displayName)
    }

    @MainActor
    func testProjectSearchNavigationCommitsCompositionSavesAndRevealsUTF16Range() async throws {
        let environment = try AppEnvironment.testing()
        let project = try await environment.projectManager.createProject(named: "전체 검색 이동")
        _ = try await environment.binderRepository.rootNodes(in: project.id)
        let firstVolume = try await environment.binderCommands.addNewVolume(projectID: project.id)
        let secondVolume = try await environment.binderCommands.addNewVolume(projectID: project.id)
        let loadedFirst = try await environment.documentRepository.document(
            id: firstVolume.documentToOpenID
        )
        let loadedSecond = try await environment.documentRepository.document(
            id: secondVolume.documentToOpenID
        )
        let first = try XCTUnwrap(loadedFirst)
        let second = try XCTUnwrap(loadedSecond)
        _ = try await environment.localDocumentStore.save(
            DocumentSaveRequest(
                projectID: project.id,
                documentID: second.id,
                relativePath: second.relativePath,
                text: "앞🙂검색어뒤",
                generation: 1
            )
        )
        let firstNode = BinderNode(
            id: first.id,
            projectID: project.id,
            kind: .text,
            relativePath: first.relativePath,
            displayName: "001화",
            fixedCategory: nil,
            userOrder: first.userOrder,
            contentState: .empty,
            isExpanded: false
        )
        let model = EditorSessionModel(
            documentRepository: environment.documentRepository,
            documentStore: environment.localDocumentStore,
            workspaceStateRepository: environment.workspaceStateRepository
        )

        await model.requestSelection(firstNode)
        model.updateText("조합 중에도 저장할 원고")
        await model.updateCompositionState(true)
        let commitRequest = model.compositionCommitRequest
        let revealRequest = model.selectionNavigationRequest

        await model.requestSearchNavigation(
            documentID: second.id,
            displayName: "001화",
            cursor: TextCursorState(location: 3, selectionLength: 3)
        )

        XCTAssertEqual(model.currentDocumentID, first.id)
        XCTAssertEqual(model.pendingDisplayName, "001화")
        XCTAssertGreaterThan(model.compositionCommitRequest, commitRequest)

        await model.updateCompositionState(false)

        XCTAssertEqual(model.currentDocumentID, second.id)
        XCTAssertEqual(model.cursor, TextCursorState(location: 3, selectionLength: 3))
        XCTAssertGreaterThan(model.selectionNavigationRequest, revealRequest)
        XCTAssertNil(model.pendingDisplayName)
        let savedFirstText = try await environment.localDocumentStore.loadText(for: first)
        XCTAssertEqual(savedFirstText, "조합 중에도 저장할 원고")

        let sameDocumentRevealRequest = model.selectionNavigationRequest
        await model.requestSearchNavigation(
            documentID: second.id,
            displayName: "001화",
            cursor: TextCursorState(location: 100, selectionLength: 10)
        )
        XCTAssertEqual(model.cursor, TextCursorState(location: 7, selectionLength: 0))
        XCTAssertGreaterThan(model.selectionNavigationRequest, sameDocumentRevealRequest)
    }

    @MainActor
    private func waitForStatistics(
        _ expectedCount: Int,
        in model: EditorSessionModel
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while model.statistics.characterCount != expectedCount, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.statistics.characterCount, expectedCount)
    }

    private func textRuleRequest(
        text: String,
        location: UInt,
        selectionLength: UInt = 0,
        changeLocation: UInt? = nil,
        changeLength: UInt? = nil,
        replacement: String,
        settings: TextRuleSettings = .enabled,
        isComposing: Bool = false,
        isPaste: Bool = false
    ) -> TextRuleRequest {
        let selection = TextCursorState(location: location, selectionLength: selectionLength)
        return TextRuleRequest(
            text: text,
            selection: selection,
            changeRange: TextCursorState(
                location: changeLocation ?? location,
                selectionLength: changeLength ?? selectionLength
            ),
            replacementText: replacement,
            settings: settings,
            isComposing: isComposing,
            isPaste: isPaste
        )
    }
}

private actor AlwaysAuthenticatedService: AuthenticationServicing {
    private let state = AuthenticationState.authenticated(
        AuthenticatedAccount(
            userID: UUID(),
            maskedEmail: "u***@example.com"
        )
    )

    func currentState() -> AuthenticationState { state }
    func restoreSession() -> AuthenticationState { state }
    // 이 고정 상태 더블은 refresh와 restore를 의도적으로 구분하지 않는다.
    func refreshSession(force: Bool) -> AuthenticationState {
        _ = force
        return state
    }
    func signIn(
        email: String,
        password: String
    ) -> AuthenticationState {
        state
    }
    func signOut() -> AuthenticationState { .signedOut(.userInitiated) }
}

private actor CloudStartupAuthenticationSpy: AuthenticationServicing {
    private var restoreCalls = 0

    func restoreCallCount() -> Int { restoreCalls }
    func currentState() -> AuthenticationState { .signedOut(.noStoredSession) }
    func restoreSession() -> AuthenticationState {
        restoreCalls += 1
        return .signedOut(.noStoredSession)
    }
    func refreshSession(force: Bool) -> AuthenticationState {
        _ = force
        return .signedOut(.noStoredSession)
    }
    func signIn(
        email: String,
        password: String
    ) -> AuthenticationState {
        _ = email
        _ = password
        return .signedOut(.noStoredSession)
    }
    func signOut() -> AuthenticationState { .signedOut(.userInitiated) }
}

private actor CloudStartupDeviceIdentitySpy: DeviceIdentityProviding {
    private var prepareCalls = 0

    func prepareCallCount() -> Int { prepareCalls }
    func currentState() -> DeviceIdentityState { .uninitialized }
    func currentIdentifier() async throws -> DeviceIdentifier {
        throw DeviceIdentityFailure.keychainAccess
    }
    func prepareIdentity() async {
        prepareCalls += 1
    }
}

private actor DelayedNewProjectBindingService: ProjectBindingServicing {
    private var createContinuation:
        CheckedContinuation<ProjectBindingResult, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var binding: ProjectSyncBinding?
    private var pendingProjectID: ProjectID?

    func currentBinding(
        for localProjectID: ProjectID
    ) -> ProjectSyncBinding? {
        guard binding?.localProjectID == localProjectID else { return nil }
        return binding
    }

    func createServerProject(
        for localProjectID: ProjectID
    ) async -> ProjectBindingResult {
        await withCheckedContinuation { continuation in
            pendingProjectID = localProjectID
            createContinuation = continuation
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilCreateStarts() async {
        guard createContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseCreate() {
        guard let continuation = createContinuation,
              let projectID = pendingProjectID else { return }
        let connected = ProjectSyncBinding.connected(
            localProjectID: projectID,
            serverProjectID: projectID.rawValue,
            kind: .newServerProject,
            projectName: "binding 대기 작품",
            ownerSubject: UUID()
        )
        binding = connected
        createContinuation = nil
        pendingProjectID = nil
        continuation.resume(returning: .connected(connected))
    }

    func connectExistingProject(
        localProjectID: ProjectID,
        confirmation: ConfirmedServerProjectID
    ) -> ProjectBindingResult {
        .failed(.serverRejected)
    }

    func connectWindowsProject(
        localProjectID: ProjectID,
        confirmation: ConfirmedServerProjectID
    ) -> ProjectBindingResult {
        .failed(.serverRejected)
    }

    func refreshServerName(
        for localProjectID: ProjectID
    ) -> ProjectBindingResult {
        .failed(.serverRejected)
    }

    func disconnect(
        localProjectID: ProjectID
    ) -> ProjectBindingResult {
        .failed(.serverRejected)
    }
}

private actor AutosaveSleepProbe {
    private var delays: [Duration] = []

    func record(_ duration: Duration) {
        delays.append(duration)
    }

    func recordedDelays() -> [Duration] {
        delays
    }
}

private actor ControllableFailingDocumentStore: LocalDocumentStoring {
    private let underlying: any LocalDocumentStoring
    private var isSaveFailureEnabled = false

    init(underlying: any LocalDocumentStoring) {
        self.underlying = underlying
    }

    func setSaveFailureEnabled(_ enabled: Bool) {
        isSaveFailureEnabled = enabled
    }

    func loadText(for document: DocumentNode) async throws -> String {
        try await underlying.loadText(for: document)
    }

    func save(_ request: DocumentSaveRequest) async throws -> DocumentSaveReceipt {
        if isSaveFailureEnabled {
            throw ControllableSaveError.injectedFailure
        }
        return try await underlying.save(request)
    }
}

private enum ControllableSaveError: LocalizedError {
    case injectedFailure

    var errorDescription: String? { "테스트 로컬 저장 실패" }
}

private actor FirstSaveDelayingDocumentStore: LocalDocumentStoring {
    private let underlying: any LocalDocumentStoring
    private var submittedSaveCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstSaveContinuation: CheckedContinuation<Void, Never>?

    init(underlying: any LocalDocumentStoring) {
        self.underlying = underlying
    }

    func loadText(for document: DocumentNode) async throws -> String {
        try await underlying.loadText(for: document)
    }

    func save(_ request: DocumentSaveRequest) async throws -> DocumentSaveReceipt {
        submittedSaveCount += 1
        if submittedSaveCount == 1 {
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                firstSaveContinuation = continuation
            }
        }
        return try await underlying.save(request)
    }

    func waitUntilFirstSaveStarts() async {
        guard submittedSaveCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstSave() {
        firstSaveContinuation?.resume()
        firstSaveContinuation = nil
    }

    func saveCount() -> Int {
        submittedSaveCount
    }
}

private actor ScriptedSyncHandoffDocumentStore: LocalDocumentStoring {
    private let underlying: any LocalDocumentStoring
    private let saveResult: DurableRecordResult
    private var retryResults: [DurableRecordResult]
    private var submittedSaveCount = 0
    private var submittedRetryCount = 0
    private var hasPendingHandoff = false

    init(
        underlying: any LocalDocumentStoring,
        saveResult: DurableRecordResult,
        retryResults: [DurableRecordResult] = [],
        hasPendingHandoff: Bool = false
    ) {
        self.underlying = underlying
        self.saveResult = saveResult
        self.retryResults = retryResults
        self.hasPendingHandoff = hasPendingHandoff
    }

    func loadText(for document: DocumentNode) async throws -> String {
        try await underlying.loadText(for: document)
    }

    func save(_ request: DocumentSaveRequest) async throws -> DocumentSaveReceipt {
        submittedSaveCount += 1
        let receipt = try await underlying.save(request)
        if case .localSavedButNotQueued = saveResult {
            hasPendingHandoff = true
        }
        return receipt.recording(saveResult)
    }

    func retryPendingSyncHandoff(
        for document: DocumentNode
    ) async -> DurableRecordResult {
        _ = document
        guard hasPendingHandoff else { return .localOnly }
        submittedRetryCount += 1
        guard !retryResults.isEmpty else {
            return .localSavedButNotQueued(reason: "retry exhausted")
        }
        let result = retryResults.removeFirst()
        if case .queued = result {
            hasPendingHandoff = false
        }
        return result
    }

    func saveCount() -> Int {
        submittedSaveCount
    }

    func retryCount() -> Int {
        submittedRetryCount
    }
}

/// 테스트가 직접 시간을 돌리는 시계다. `advance`가 불릴 때만 시각이 흐르고,
/// 그때 마감이 지난 대기만 깨운다. 실제 시계와 달리 기계 부하에 흔들리지 않는다.
///
/// 대기가 등록되기 전에 시간을 돌리면 그 대기는 이미 지나간 마감을 잡아 영영
/// 깨어나지 못한다. `waitForSleep`으로 등록을 확인한 뒤에 돌려야 한다.
private enum VirtualSleepRegistration: Equatable, Sendable {
    case suspended
    case completedWithoutSuspending
    case timedOut
}

private final class VirtualStatisticsClock: @unchecked Sendable {
    private struct Waiter {
        let id: UInt64
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct SleepObserver {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private let base = ContinuousClock().now
    private let registrationBackstop: Duration
    private var elapsed: Duration = .zero
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0
    private var sleepCallCount = 0
    private var didLastSleepSuspend = false
    private var sleepObservers: [SleepObserver] = []
    private var nextObserverID: UInt64 = 0

    init(registrationBackstop: Duration = .seconds(10)) {
        self.registrationBackstop = registrationBackstop
    }

    func now() -> ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return base.advanced(by: elapsed)
    }

    /// 지금까지 접수된 `sleep` 호출 수다. `waitForSleep`의 기준점으로 쓴다.
    func sleepCount() -> Int {
        lock.withLock { sleepCallCount }
    }

    /// `previous` 이후의 새 `sleep`이 실제로 멈췄는지, 멈추지 않고 끝났는지,
    /// 등록 자체가 제한시간 안에 오지 않았는지를 서로 다른 값으로 돌려준다.
    func waitForSleep(after previous: Int) async -> VirtualSleepRegistration {
        if let didSuspend = sleepOutcome(after: previous) {
            return didSuspend ? .suspended : .completedWithoutSuspending
        }
        let id: UInt64 = lock.withLock {
            nextObserverID += 1
            return nextObserverID
        }
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            let alreadyArrived: Bool = lock.withLock {
                guard sleepCallCount <= previous else { return true }
                sleepObservers.append(
                    SleepObserver(id: id, continuation: continuation)
                )
                return false
            }
            if alreadyArrived {
                continuation.resume()
                return
            }
            Task {
                try? await ContinuousClock().sleep(
                    for: self.registrationBackstop
                )
                self.resumeSleepObserver(id)
            }
        }
        guard let didSuspend = sleepOutcome(after: previous) else {
            return .timedOut
        }
        return didSuspend ? .suspended : .completedWithoutSuspending
    }

    /// 깨운 대기 수를 돌려준다. 0이면 이번 진행으로는 아무 계산도 깨어나지 않는다.
    @discardableResult
    func advance(by duration: Duration) -> Int {
        lock.lock()
        elapsed += duration
        let due = waiters.filter { $0.deadline <= elapsed }
        waiters.removeAll { $0.deadline <= elapsed }
        lock.unlock()
        for waiter in due {
            waiter.continuation.resume()
        }
        return due.count
    }

    func sleep(for duration: Duration) async throws {
        guard duration > .zero else {
            noteSleep(didSuspend: false)
            return
        }
        let (deadline, id): (Duration, UInt64) = lock.withLock {
            nextWaiterID += 1
            return (elapsed + duration, nextWaiterID)
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if elapsed >= deadline {
                    lock.unlock()
                    noteSleep(didSuspend: false)
                    continuation.resume()
                    return
                }
                waiters.append(
                    Waiter(
                        id: id,
                        deadline: deadline,
                        continuation: continuation
                    )
                )
                lock.unlock()
                noteSleep(didSuspend: true)
            }
        } onCancel: {
            // 취소된 대기만 깨운다. 마감 시각이 같은 대기가 여럿일 수 있으므로
            // 시각이 아니라 고유 번호로 찾아야 남의 대기를 지우지 않는다.
            let cancelled: [Waiter] = lock.withLock {
                let matched = waiters.filter { $0.id == id }
                waiters.removeAll { $0.id == id }
                return matched
            }
            for waiter in cancelled {
                waiter.continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func sleepOutcome(after previous: Int) -> Bool? {
        lock.withLock {
            sleepCallCount > previous ? didLastSleepSuspend : nil
        }
    }

    /// `sleep` 호출이 접수되었음을 기록하고, 기다리던 시험을 깨운다.
    private func noteSleep(didSuspend: Bool) {
        let observers: [SleepObserver] = lock.withLock {
            sleepCallCount += 1
            didLastSleepSuspend = didSuspend
            let pending = sleepObservers
            sleepObservers.removeAll()
            return pending
        }
        for observer in observers {
            observer.continuation.resume()
        }
    }

    private func resumeSleepObserver(_ id: UInt64) {
        let matched: [SleepObserver] = lock.withLock {
            let found = sleepObservers.filter { $0.id == id }
            sleepObservers.removeAll { $0.id == id }
            return found
        }
        for observer in matched {
            observer.continuation.resume()
        }
    }
}
