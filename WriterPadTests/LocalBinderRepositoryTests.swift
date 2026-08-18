import Foundation
import SwiftData
import XCTest
@testable import WriterPad

final class LocalBinderRepositoryTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots = []
    }

    @MainActor
    func testTopLevelTextDiscoveredOnDiskIsRejectedWithoutRegisteringMetadata() async throws {
        let harness = try await makeHarness(projectName: "최상위 무결성")
        try writeText(
            "잘못된 위치",
            workspace: harness.workspace,
            path: "메인/최상위 문서.txt"
        )

        do {
            _ = try await harness.binder.rootNodes(in: harness.project.id)
            XCTFail("최상위 문서가 바인더에 등록되었습니다.")
        } catch let error as BinderRepositoryError {
            XCTAssertEqual(
                error,
                .documentAtTopLevel("메인/최상위 문서.txt")
            )
        }

        let metadata = try await harness.repository.documents(in: harness.project.id)
        XCTAssertFalse(
            metadata.contains {
                $0.relativePath.rawValue == "메인/최상위 문서.txt"
            }
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: harness.workspace
                    .appendingPathComponent("메인/최상위 문서.txt")
                    .path
            )
        )
    }

    @MainActor
    func testMissingEmptyFixedTrashIsRecreatedWithoutChangingOtherItems()
        async throws {
        let harness = try await makeHarness(projectName: "빈 고정 폴더 복구")
        try writeText(
            "그대로 남아야 함",
            workspace: harness.workspace,
            path: "메인/메모장/보존.txt"
        )
        let preservedURL = harness.workspace
            .appendingPathComponent("메인/메모장/보존.txt")
        let preservedBefore = try Data(contentsOf: preservedURL)
        let trashURL = harness.workspace.appendingPathComponent("메인/휴지통")
        try FileManager.default.removeItem(at: trashURL)

        let roots = try await harness.binder.rootNodes(in: harness.project.id)

        XCTAssertNotNil(roots.first { $0.fixedCategory == .trash })
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashURL.path))
        XCTAssertEqual(try Data(contentsOf: preservedURL), preservedBefore)
        let storedTrash = try await harness.repository
            .documents(in: harness.project.id)
            .first {
                $0.relativePath == BinderFixedCategory.trash.relativePath
            }
        XCTAssertEqual(storedTrash?.kind, .folder)
    }

    @MainActor
    func testThousandChapterProjectInitiallyScansOnlyMainAndShowsNineFixedRoots() async throws {
        let harness = try await makeHarness(projectName: "천화 작품")
        let manuscript = harness.workspace.appendingPathComponent("메인/원고/1권")
        try FileManager.default.createDirectory(at: manuscript, withIntermediateDirectories: true)
        for chapter in 1...1_000 {
            try Data("본문 \(chapter)".utf8).write(
                to: manuscript.appendingPathComponent(String(format: "%04d화.txt", chapter))
            )
        }
        try FileManager.default.createDirectory(
            at: harness.workspace.appendingPathComponent("메인/플롯"),
            withIntermediateDirectories: true
        )
        await harness.scanner.resetMetrics()

        let roots = try await harness.binder.rootNodes(in: harness.project.id)
        let metrics = await harness.scanner.metrics()
        let metadata = try await harness.repository.documents(in: harness.project.id)

        XCTAssertEqual(
            Array(roots.prefix(8).compactMap(\.fixedCategory)),
            BinderFixedCategory.allCases.filter { $0 != .trash }
        )
        XCTAssertEqual(roots.first?.fixedCategory, .manuscript)
        XCTAssertEqual(roots.last?.fixedCategory, .trash)
        XCTAssertEqual(roots.dropLast().last?.displayName, "플롯")
        XCTAssertNil(roots.dropLast().last?.fixedCategory)
        XCTAssertEqual(metrics.relativeDirectories, ["메인"])
        XCTAssertFalse(metrics.performedMainThreadIO)
        XCTAssertFalse(metadata.contains { $0.relativePath.rawValue.contains("1권") })
    }

    @MainActor
    func testFoldersAndTextUseNaturalOrderHideExtensionAndExposeContentState() async throws {
        let harness = try await makeHarness(projectName: "정렬 작품")
        for volume in ["10권", "2권", "1권"] {
            try FileManager.default.createDirectory(
                at: harness.workspace.appendingPathComponent("메인/원고/\(volume)"),
                withIntermediateDirectories: true
            )
        }
        try writeText("열 번째", workspace: harness.workspace, path: "메인/원고/1권/010화.txt")
        try writeText("", workspace: harness.workspace, path: "메인/원고/1권/002화.txt")
        try writeText("첫 번째", workspace: harness.workspace, path: "메인/원고/1권/001화.txt")

        let roots = try await harness.binder.rootNodes(in: harness.project.id)
        let manuscript = try XCTUnwrap(roots.first { $0.fixedCategory == .manuscript })
        let volumes = try await harness.binder.children(
            of: manuscript.id,
            in: harness.project.id
        )
        let firstVolume = try XCTUnwrap(volumes.first)
        let chapters = try await harness.binder.children(
            of: firstVolume.id,
            in: harness.project.id
        )

        XCTAssertEqual(volumes.map(\.displayName), ["1권", "2권", "10권"])
        XCTAssertEqual(chapters.map(\.displayName), ["001화", "002화", "010화"])
        XCTAssertFalse(chapters.contains { $0.displayName.lowercased().hasSuffix(".txt") })
        XCTAssertTrue(chapters.allSatisfy {
            $0.relativePath.rawValue.lowercased().hasSuffix(".txt")
        })
        XCTAssertEqual(chapters[0].contentState, .written)
        XCTAssertEqual(chapters[1].contentState, .empty)
        XCTAssertEqual(chapters[2].contentState, .written)

        let firstStored = try await harness.repository.document(id: volumes[0].id)
        let tenthStored = try await harness.repository.document(id: volumes[2].id)
        let first = try XCTUnwrap(firstStored)
        let tenth = try XCTUnwrap(tenthStored)
        try await harness.repository.save(
            first.relocated(
                to: first.relativePath,
                parentID: first.parentID,
                userOrder: 100,
                at: first.modifiedAt
            )
        )
        try await harness.repository.save(
            tenth.relocated(
                to: tenth.relativePath,
                parentID: tenth.parentID,
                userOrder: 0,
                at: tenth.modifiedAt
            )
        )
        let manuscriptOrder = try await harness.binder.children(
            of: manuscript.id,
            in: harness.project.id
        )
        XCTAssertEqual(manuscriptOrder.map(\.displayName), ["1권", "2권", "10권"])
    }

    @MainActor
    func testStoredUserOrderOverridesNaturalOrder() async throws {
        let harness = try await makeHarness(projectName: "사용자 정렬")
        try writeText("첫째", workspace: harness.workspace, path: "메인/메모장/1.txt")
        try writeText("둘째", workspace: harness.workspace, path: "메인/메모장/2.txt")
        let roots = try await harness.binder.rootNodes(in: harness.project.id)
        let notes = try XCTUnwrap(roots.first { $0.fixedCategory == .notes })
        let natural = try await harness.binder.children(of: notes.id, in: harness.project.id)
        let storedFirst = try await harness.repository.document(id: natural[0].id)
        let storedSecond = try await harness.repository.document(id: natural[1].id)
        let first = try XCTUnwrap(storedFirst)
        let second = try XCTUnwrap(storedSecond)
        try await harness.repository.save(
            first.relocated(
                to: first.relativePath,
                parentID: first.parentID,
                userOrder: 20,
                at: first.modifiedAt
            )
        )
        try await harness.repository.save(
            second.relocated(
                to: second.relativePath,
                parentID: second.parentID,
                userOrder: 10,
                at: second.modifiedAt
            )
        )

        let reordered = try await harness.binder.children(of: notes.id, in: harness.project.id)

        XCTAssertEqual(reordered.map(\.displayName), ["2", "1"])
        XCTAssertEqual(reordered.map(\.id), [second.id, first.id])
    }

    @MainActor
    func testExpandedBranchesRestoreThroughViewModelWithoutLoadingCollapsedSiblings() async throws {
        let harness = try await makeHarness(projectName: "펼침 복원")
        try writeText("본문", workspace: harness.workspace, path: "메인/원고/1권/001화.txt")
        let roots = try await harness.binder.rootNodes(in: harness.project.id)
        let manuscript = try XCTUnwrap(roots.first { $0.fixedCategory == .manuscript })
        let volumes = try await harness.binder.children(of: manuscript.id, in: harness.project.id)
        let volume = try XCTUnwrap(volumes.first)
        try await harness.binder.setExpanded(true, for: manuscript.id)
        try await harness.binder.setExpanded(true, for: volume.id)
        await harness.scanner.resetMetrics()

        let model = BinderViewModel(
            repository: harness.binder,
            commands: harness.commands
        )
        await model.load(projectID: harness.project.id)
        let metrics = await harness.scanner.metrics()

        XCTAssertTrue(model.roots.first { $0.id == manuscript.id }?.isExpanded == true)
        XCTAssertEqual(
            model.visibleRows.first { $0.node.id == volume.id }?.depth,
            1
        )
        XCTAssertEqual(
            model.visibleRows.first { $0.node.displayName == "001화" }?.depth,
            2
        )
        XCTAssertEqual(metrics.relativeDirectories, ["메인", "메인/원고", "메인/원고/1권"])
    }

    @MainActor
    func testBackgroundReloadKeepsVisibleRowsAndSelectionUntilReplacementIsReady()
        async throws {
        let harness = try await makeHarness(projectName: "무깜빡임 갱신")
        try writeText(
            "기존 본문",
            workspace: harness.workspace,
            path: "메인/메모장/기존.txt"
        )
        let roots = try await harness.binder.rootNodes(in: harness.project.id)
        let notes = try XCTUnwrap(roots.first { $0.fixedCategory == .notes })
        try await harness.binder.setExpanded(true, for: notes.id)

        let repository = BlockingBinderRepository(base: harness.binder)
        let model = BinderViewModel(
            repository: repository,
            commands: harness.commands
        )
        await model.load(projectID: harness.project.id)
        let existing = try XCTUnwrap(
            model.visibleRows.first { $0.node.displayName == "기존" }?.node
        )
        model.select(existing)
        let rowsBeforeRefresh = model.visibleRows

        await repository.blockNextRootLoad()
        let refresh = Task { @MainActor in
            await model.load(projectID: harness.project.id)
        }
        await repository.waitUntilRootLoadIsBlocked()

        XCTAssertEqual(model.visibleRows, rowsBeforeRefresh)
        XCTAssertEqual(model.selectedNodeID, existing.id)

        try writeText(
            "서버에서 추가된 본문",
            workspace: harness.workspace,
            path: "메인/메모장/추가.txt"
        )
        await repository.resumeRootLoad()
        await refresh.value

        XCTAssertNotNil(
            model.visibleRows.first { $0.node.displayName == "추가" }
        )
        XCTAssertEqual(model.selectedNodeID, existing.id)
    }

    @MainActor
    func testCreateRefreshesOnlyParentBranchAndKeepsOtherExpandedBranches() async throws {
        let harness = try await makeHarness(projectName: "부분 생성 갱신")
        try writeText("본문", workspace: harness.workspace, path: "메인/원고/1권/001화.txt")
        let roots = try await harness.binder.rootNodes(in: harness.project.id)
        let manuscript = try XCTUnwrap(roots.first { $0.fixedCategory == .manuscript })
        let notes = try XCTUnwrap(roots.first { $0.fixedCategory == .notes })
        let volumes = try await harness.binder.children(
            of: manuscript.id,
            in: harness.project.id
        )
        let volume = try XCTUnwrap(volumes.first)
        try await harness.binder.setExpanded(true, for: manuscript.id)
        try await harness.binder.setExpanded(true, for: volume.id)
        try await harness.binder.setExpanded(true, for: notes.id)

        let model = BinderViewModel(repository: harness.binder, commands: harness.commands)
        await model.load(projectID: harness.project.id)
        await harness.scanner.resetMetrics()

        await model.create(kind: .folder, named: "빠른 폴더", in: notes)
        let metrics = await harness.scanner.metrics()

        XCTAssertEqual(metrics.relativeDirectories, ["메인/메모장"])
        XCTAssertNotNil(model.visibleRows.first { $0.node.displayName == "빠른 폴더" })
        XCTAssertNotNil(model.visibleRows.first { $0.node.displayName == "001화" })
        XCTAssertEqual(
            model.selectedNodeID,
            model.visibleRows.first { $0.node.displayName == "빠른 폴더" }?.node.id
        )
    }

    @MainActor
    func testCreateRootFolderRefreshesOnlyRootsAndPreservesLoadedChildren() async throws {
        let harness = try await makeHarness(projectName: "최상위 부분 갱신")
        try writeText("기존", workspace: harness.workspace, path: "메인/메모장/기존.txt")
        let roots = try await harness.binder.rootNodes(in: harness.project.id)
        let notes = try XCTUnwrap(roots.first { $0.fixedCategory == .notes })
        try await harness.binder.setExpanded(true, for: notes.id)
        let model = BinderViewModel(repository: harness.binder, commands: harness.commands)
        await model.load(projectID: harness.project.id)
        await harness.scanner.resetMetrics()

        await model.createRootFolder(named: "자료")
        let metrics = await harness.scanner.metrics()

        XCTAssertEqual(metrics.relativeDirectories, ["메인"])
        XCTAssertNotNil(model.roots.first { $0.displayName == "자료" })
        XCTAssertNotNil(model.visibleRows.first { $0.node.displayName == "기존" })
        XCTAssertEqual(
            model.selectedNodeID,
            model.roots.first { $0.displayName == "자료" }?.id
        )
    }

    @MainActor
    func testBinderScanAndEmptyFolderCreationShareProjectStructureGate()
        async throws {
        let harness = try await makeHarness(projectName: "구조 경쟁 방지")
        let roots = try await harness.binder.rootNodes(in: harness.project.id)
        let notes = try XCTUnwrap(
            roots.first { $0.fixedCategory == .notes }
        )
        await harness.scanner.resetMetrics()
        let blocker = SequencedBinderStructureOperation()
        let structureID = syncV2ProjectStructureMutationID(harness.project.id)
        let holder = Task {
            try await harness.mutationGate.withCriticalSection(
                documentID: structureID
            ) {
                await blocker.run()
            }
        }
        await blocker.waitUntilStarted()

        let reload = Task {
            try await harness.binder.rootNodes(in: harness.project.id)
        }
        let create = Task {
            try await harness.commands.create(
                kind: .folder,
                named: "동시 생성",
                in: notes.id,
                projectID: harness.project.id
            )
        }
        for _ in 0..<100 { await Task.yield() }

        let metricsWhileHeld = await harness.scanner.metrics()
        XCTAssertTrue(metricsWhileHeld.relativeDirectories.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: harness.workspace
                    .appendingPathComponent("메인/메모장/동시 생성")
                    .path
            )
        )

        await blocker.release()
        _ = try await holder.value
        let reloadedRoots = try await reload.value
        _ = try await create.value

        XCTAssertNotNil(
            reloadedRoots.first { $0.fixedCategory == .trash }
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: harness.workspace
                    .appendingPathComponent("메인/메모장/동시 생성")
                    .path
            )
        )
    }

    @MainActor
    func testTrashMoveInvalidatesCollapsedEmptyCacheAndAppearsOnNextExpansion() async throws {
        let harness = try await makeHarness(projectName: "휴지통 실시간 갱신")
        let roots = try await harness.binder.rootNodes(in: harness.project.id)
        let notes = try XCTUnwrap(roots.first { $0.fixedCategory == .notes })
        let trash = try XCTUnwrap(roots.first { $0.fixedCategory == .trash })
        try await harness.binder.setExpanded(true, for: notes.id)
        try await harness.binder.setExpanded(true, for: trash.id)

        let model = BinderViewModel(repository: harness.binder, commands: harness.commands)
        await model.load(projectID: harness.project.id)
        let initiallyExpandedTrash = try XCTUnwrap(
            model.roots.first { $0.id == trash.id }
        )
        XCTAssertEqual(model.childrenByParent[trash.id], [])
        await model.toggleExpansion(of: initiallyExpandedTrash)

        await model.create(kind: .folder, named: "바로 삭제", in: notes)
        let folder = try XCTUnwrap(
            model.childrenByParent[notes.id]?.first { $0.displayName == "바로 삭제" }
        )
        await model.create(kind: .text, named: "하위 문서", in: folder)
        await model.moveToTrash(folder)

        XCTAssertNil(model.childrenByParent[trash.id])
        let refreshedTrash = try XCTUnwrap(model.roots.first { $0.id == trash.id })
        await model.toggleExpansion(of: refreshedTrash)

        XCTAssertEqual(
            model.childrenByParent[trash.id]?.map(\.displayName),
            ["바로 삭제"]
        )
    }

    @MainActor
    func testMixedFolderAndTextSiblingsCanBeReordered() async throws {
        let harness = try await makeHarness(projectName: "혼합 순서 변경")
        let roots = try await harness.binder.rootNodes(in: harness.project.id)
        let notes = try XCTUnwrap(roots.first { $0.fixedCategory == .notes })
        try await harness.binder.setExpanded(true, for: notes.id)
        let model = BinderViewModel(repository: harness.binder, commands: harness.commands)
        await model.load(projectID: harness.project.id)
        await model.create(kind: .folder, named: "새폴더", in: notes)
        await model.create(kind: .text, named: "새문서", in: notes)
        await model.create(kind: .text, named: "새문서_2", in: notes)

        let initial = try XCTUnwrap(model.childrenByParent[notes.id])
        let folder = try XCTUnwrap(initial.first { $0.displayName == "새폴더" })
        let secondText = try XCTUnwrap(initial.first { $0.displayName == "새문서_2" })
        let didReorder = await model.reorder(
            folder.id,
            relativeTo: secondText.id,
            placeAfter: true
        )

        XCTAssertTrue(didReorder)
        XCTAssertEqual(
            model.childrenByParent[notes.id]?.map(\.displayName),
            ["새문서", "새문서_2", "새폴더"]
        )
    }

    @MainActor
    func testExternalTextRenameKeepsUUIDWhenHashMatchIsUnique() async throws {
        let harness = try await makeHarness(projectName: "외부 변경")
        try writeText("동일한 본문", workspace: harness.workspace, path: "메인/메모장/초안.txt")
        let roots = try await harness.binder.rootNodes(in: harness.project.id)
        let notes = try XCTUnwrap(roots.first { $0.fixedCategory == .notes })
        let before = try await harness.binder.children(of: notes.id, in: harness.project.id)
        let source = harness.workspace.appendingPathComponent("메인/메모장/초안.txt")
        let destination = harness.workspace.appendingPathComponent("메인/메모장/완성.txt")
        try FileManager.default.moveItem(at: source, to: destination)

        let after = try await harness.binder.children(of: notes.id, in: harness.project.id)
        let stored = try await harness.repository.document(id: before[0].id)

        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(after.first?.displayName, "완성")
        XCTAssertEqual(stored?.relativePath.rawValue, "메인/메모장/완성.txt")
    }

    @MainActor
    func testExternalAdditionKeepsExistingUUIDAndCreatesOnlyOneNewIdentity() async throws {
        let harness = try await makeHarness(projectName: "외부 추가")
        try writeText("기존", workspace: harness.workspace, path: "메인/설정집/기존.txt")
        let roots = try await harness.binder.rootNodes(in: harness.project.id)
        let settings = try XCTUnwrap(roots.first { $0.fixedCategory == .settings })
        let before = try await harness.binder.children(of: settings.id, in: harness.project.id)
        try writeText("새 문서", workspace: harness.workspace, path: "메인/설정집/추가.txt")

        let after = try await harness.binder.children(of: settings.id, in: harness.project.id)

        XCTAssertEqual(after.count, 2)
        XCTAssertTrue(after.contains { $0.id == before[0].id })
        XCTAssertEqual(Set(after.map(\.id)).count, 2)
    }

    private struct Harness {
        let root: URL
        let container: ModelContainer
        let repository: SwiftDataMetadataRepository
        let resolver: ProjectPathResolver
        let scanner: LocalBinderDirectoryScanner
        let binder: LocalBinderRepository
        let commands: LocalBinderCommandService
        let mutationGate: SyncV2DocumentMutationGate
        let project: ManagedProject
        let workspace: URL
    }

    private actor BlockingBinderRepository: BinderRepository {
        private let base: any BinderRepository
        private var shouldBlockNextRootLoad = false
        private var rootLoadIsBlocked = false
        private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
        private var rootLoadContinuation: CheckedContinuation<Void, Never>?

        init(base: any BinderRepository) {
            self.base = base
        }

        func blockNextRootLoad() {
            shouldBlockNextRootLoad = true
        }

        func waitUntilRootLoadIsBlocked() async {
            guard !rootLoadIsBlocked else { return }
            await withCheckedContinuation { continuation in
                blockedWaiters.append(continuation)
            }
        }

        func resumeRootLoad() {
            rootLoadContinuation?.resume()
            rootLoadContinuation = nil
        }

        func rootContainerID(in projectID: ProjectID) async throws -> DocumentID {
            try await base.rootContainerID(in: projectID)
        }

        func rootNodes(in projectID: ProjectID) async throws -> [BinderNode] {
            if shouldBlockNextRootLoad {
                shouldBlockNextRootLoad = false
                rootLoadIsBlocked = true
                let waiters = blockedWaiters
                blockedWaiters.removeAll()
                waiters.forEach { $0.resume() }
                await withCheckedContinuation { continuation in
                    rootLoadContinuation = continuation
                }
                rootLoadIsBlocked = false
            }
            return try await base.rootNodes(in: projectID)
        }

        func children(
            of folderID: DocumentID,
            in projectID: ProjectID
        ) async throws -> [BinderNode] {
            try await base.children(of: folderID, in: projectID)
        }

        func setExpanded(
            _ isExpanded: Bool,
            for folderID: DocumentID
        ) async throws {
            try await base.setExpanded(isExpanded, for: folderID)
        }
    }

    private struct FixedClock: AppClock {
        let date: Date
        func now() -> Date { date }
    }

    @MainActor
    private func makeHarness(projectName: String) async throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriterPad-BinderTests-\(UUID().uuidString)")
        roots.append(root)
        let container = try WriterPadMetadataStore.makeContainer(isStoredInMemoryOnly: true)
        let repository = SwiftDataMetadataRepository(modelContainer: container)
        let resolver = ProjectPathResolver(
            projectsRootURL: root.appendingPathComponent("Projects")
        )
        let clock = FixedClock(date: Date(timeIntervalSince1970: 4_000))
        let manager = LocalProjectManager(
            projectRepository: repository,
            creationMetadataStore: repository,
            workspaceStateRepository: repository,
            pathResolver: resolver,
            clock: clock
        )
        let project = try await manager.createProject(named: projectName)
        let locator = RepositoryProjectWorkspaceLocator(
            projectRepository: repository,
            pathResolver: resolver
        )
        let scanner = LocalBinderDirectoryScanner(pathResolver: resolver)
        let mutationGate = SyncV2DocumentMutationGate()
        let binder = LocalBinderRepository(
            metadataStore: repository,
            workspaceStateRepository: repository,
            workspaceLocator: locator,
            scanner: scanner,
            pathPolicy: resolver.policy,
            clock: clock,
            syncMutationGate: mutationGate
        )
        let commands = LocalBinderCommandService(
            metadataStore: repository,
            workspaceStateRepository: repository,
            workspaceLocator: locator,
            pathPolicy: resolver.policy,
            clock: clock,
            syncMutationGate: mutationGate
        )
        let workspace = try resolver.standardPaths(
            forProjectNamed: projectName
        ).workspaceRootURL
        return Harness(
            root: root,
            container: container,
            repository: repository,
            resolver: resolver,
            scanner: scanner,
            binder: binder,
            commands: commands,
            mutationGate: mutationGate,
            project: project,
            workspace: workspace
        )
    }

    private func writeText(_ text: String, workspace: URL, path: String) throws {
        let url = workspace.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}

private actor SequencedBinderStructureOperation {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func run() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
