import Foundation
import XCTest
@testable import WriterPad

@MainActor
final class AutoSaveIsolationTests: XCTestCase {
    let manifest = AutoSaveIsolationManifest.synthetic
    enum Injected: Error { case stop }
    func directory() throws -> URL {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Bootstrap-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base
    }
    func store(_ base: URL) throws -> AutoSaveIsolationStore {
        try AutoSaveIsolationStore(bundleID: AutoSaveIsolationManifest.bundleID, applicationSupport: base)
    }
    func node(_ index: Int = 0) -> DocumentNode {
        let entry = manifest.documents[index]
        return .init(id: entry.id, projectID: manifest.projectID, kind: .text, parentID: manifest.rootID,
            relativePath: .init(rawValue: manifest.path(entry)), userOrder: index, modifiedAt: Date(), contentHash: nil)
    }
    func request(_ text: String, project: ProjectID? = nil, path: String? = nil) -> DocumentSaveRequest {
        .init(projectID: project ?? manifest.projectID, documentID: manifest.documents[0].id,
            relativePath: .init(rawValue: path ?? manifest.path(manifest.documents[0])), text: text, generation: 1)
    }
    func allFiles(_ base: URL) throws -> [String: Data] {
        let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey])!
        var result: [String: Data] = [:]
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[url.path] = try Data(contentsOf: url)
        }
        return result
    }
    func testWrongBundleStopsBeforeCreatingStorage() throws {
        let base = try directory()
        for bundle in [nil, "com.chocos.writerpad.debug", "com.chocos.writerpad"] as [String?] {
            XCTAssertThrowsError(try AutoSaveIsolationStore(bundleID: bundle, applicationSupport: base)) {
                XCTAssertEqual($0 as? AutoSaveIsolationError, .bundle)
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path), [])
    }
    func testChangedProjectAndTreeManifestRefused() throws {
        let base = try directory()
        let changed = AutoSaveIsolationManifest(version: 1, projectID: IntegratedEditorPlan.local,
            rootID: manifest.rootID, rootName: IntegratedEditorPlan.rootName, documents: manifest.documents)
        XCTAssertThrowsError(try AutoSaveIsolationStore(bundleID: AutoSaveIsolationManifest.bundleID, applicationSupport: base, manifest: changed))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path), [])
    }
    func testNamespaceSymlinkCannotReachExistingContainer() throws {
        let base = try directory(), old = try directory()
        let original = old.appendingPathComponent("state.json")
        try Data("old evidence".utf8).write(to: original)
        let before = try allFiles(old)
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent(AutoSaveIsolationManifest.directory), withDestinationURL: old)
        XCTAssertThrowsError(try store(base).bootstrap())
        XCTAssertEqual(try allFiles(old), before)
    }
    func testStateAndDocumentSymlinksRefuseReadAndWrite() throws {
        for target in ["state.json", manifest.path(manifest.documents[0])] {
            let base = try directory(), s = try store(base)
            try s.bootstrap()
            let old = try directory().appendingPathComponent("original.txt")
            try Data("unsent original".utf8).write(to: old)
            let link = s.root.appendingPathComponent(target)
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: old)
            XCTAssertThrowsError(try s.bootstrap())
            XCTAssertThrowsError(try s.save(request("changed")))
            XCTAssertEqual(try String(contentsOf: old, encoding: .utf8), "unsent original")
        }
    }
    func testForeignFilesWithoutManifestAreNotAdopted() throws {
        let s = try store(directory())
        try FileManager.default.createDirectory(at: s.root, withIntermediateDirectories: true)
        let file = s.root.appendingPathComponent("sync.sqlite")
        try Data("old database".utf8).write(to: file)
        let before = try allFiles(s.root)
        XCTAssertThrowsError(try s.bootstrap())
        XCTAssertEqual(try allFiles(s.root), before)
    }
    func testInterruptedBootstrapResumesExactManifest() throws {
        for checkpoint in ["manifestCommitted", "seedWritten", "readyCommitted"] {
            let base = try directory(), s = try store(base)
            s.checkpoint = { if $0 == checkpoint { throw Injected.stop } }
            XCTAssertThrowsError(try s.bootstrap())
            let reopened = try store(base)
            try reopened.bootstrap()
            XCTAssertTrue(try reopened.snapshot().ready)
            XCTAssertEqual(try reopened.load(node()), manifest.documents[0].seed)
            let before = try allFiles(reopened.root)
            try reopened.bootstrap()
            XCTAssertEqual(try allFiles(reopened.root), before)
        }
    }
    func testPartialBootstrapDoesNotReplaceUnexpectedText() throws {
        let base = try directory(), s = try store(base)
        s.checkpoint = { if $0 == "seedWritten" { throw Injected.stop } }
        XCTAssertThrowsError(try s.bootstrap())
        let url = s.root.appendingPathComponent(manifest.path(manifest.documents[0]))
        try Data("retained unexpected text".utf8).write(to: url)
        let before = try allFiles(s.root)
        XCTAssertThrowsError(try store(base).bootstrap())
        XCTAssertEqual(try allFiles(s.root), before)
    }
    func testCorruptStateIsPreservedWithoutReset() throws {
        let s = try store(directory()); try s.bootstrap()
        try Data("{broken".utf8).write(to: s.root.appendingPathComponent("state.json"))
        let before = try allFiles(s.root)
        XCTAssertThrowsError(try s.bootstrap())
        XCTAssertThrowsError(try s.save(request("new")))
        XCTAssertEqual(try allFiles(s.root), before)
    }
    func testReadyRestartRetainsSavedTextAndNewerDraft() throws {
        let base = try directory(), s = try store(base); try s.bootstrap()
        _ = try s.save(request("saved\n"))
        try s.draft(node().id, text: "newer draft", cursor: .init(location: 2, selectionLength: 0))
        let before = try allFiles(s.root)
        let reopened = try store(base); try reopened.bootstrap()
        XCTAssertEqual(try reopened.load(node()), "saved\n")
        XCTAssertEqual(try reopened.snapshot().drafts[node().id]?.text, "newer draft")
        XCTAssertEqual(try allFiles(s.root), before)
    }
    func testInterruptedSaveRecoversBeforeAndAfterReplacement() throws {
        for checkpoint in ["saveCommitted", "textReplaced"] {
            let base = try directory(), s = try store(base); try s.bootstrap()
            try s.draft(node().id, text: "saved\n", cursor: .start)
            s.checkpoint = { if $0 == checkpoint { throw Injected.stop } }
            XCTAssertThrowsError(try s.save(request("saved\n")))
            let reopened = try store(base); try reopened.bootstrap()
            XCTAssertEqual(try reopened.load(node()), "saved\n")
            XCTAssertNil(try reopened.snapshot().records[node().id]?.pending)
            XCTAssertNil(try reopened.snapshot().drafts[node().id])
        }
    }
    func testPendingSaveDoesNotOverwriteUnexpectedTextOrNewerDraft() throws {
        let base = try directory(), s = try store(base); try s.bootstrap()
        s.checkpoint = { if $0 == "saveCommitted" { throw Injected.stop } }
        XCTAssertThrowsError(try s.save(request("older save")))
        try s.draft(node().id, text: "newer draft", cursor: .start)
        let url = s.root.appendingPathComponent(manifest.path(manifest.documents[0]))
        try Data("external edit".utf8).write(to: url)
        let before = try allFiles(s.root)
        XCTAssertThrowsError(try store(base).bootstrap())
        XCTAssertEqual(try allFiles(s.root), before)
    }
    func testSaveScopeAndPathCannotTargetOldTree() throws {
        let s = try store(directory()); try s.bootstrap()
        let before = try allFiles(s.root)
        XCTAssertThrowsError(try s.save(request("new", project: IntegratedEditorPlan.local)))
        for path in ["../original.txt", IntegratedEditorPlan.rootPath + "/A.txt", "/tmp/escape.txt"] {
            XCTAssertThrowsError(try s.save(request("new", path: path)))
        }
        XCTAssertEqual(try allFiles(s.root), before)
    }
    func testNeighborEvidenceUnchangedAcrossSaveFailureAndRecovery() throws {
        let parent = try directory(), old = parent.appendingPathComponent("existing-app")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let evidence = ["original-R.txt": Data(repeating: 65, count: 18), "original-A.txt": Data(repeating: 66, count: 19),
            "journal.json": Data("{\"requests\":323,\"auth\":12,\"writes\":17,\"expiresAt\":\"2026-09-13T06:00:00Z\",\"conflict\":true}".utf8),
            "sync.sqlite": Data("synthetic database evidence".utf8), "installed.zip": Data("synthetic installed evidence".utf8)]
        for (path, data) in evidence { try data.write(to: old.appendingPathComponent(path)) }
        let before = try allFiles(old), new = parent.appendingPathComponent("new-app")
        let s = try store(new); try s.bootstrap()
        s.checkpoint = { if $0 == "textReplaced" { throw Injected.stop } }
        XCTAssertThrowsError(try s.save(request("new local content")))
        try store(new).bootstrap()
        XCTAssertEqual(try allFiles(old), before)
    }
    func testRecoveryPreservesByteDistinctNewerDraft() throws {
        let base = try directory(), s = try store(base); try s.bootstrap()
        s.checkpoint = { if $0 == "saveCommitted" { throw Injected.stop } }
        XCTAssertThrowsError(try s.save(request("é")))
        try s.draft(node().id, text: "e\u{301}", cursor: .start)
        let reopened = try store(base); try reopened.bootstrap()
        XCTAssertEqual(Data(try reopened.load(node()).utf8), Data("é".utf8))
        XCTAssertEqual(try reopened.snapshot().drafts[node().id].map { Data($0.text.utf8) }, Data("e\u{301}".utf8))
    }
    func testPersistedManifestChangeBlocksWithoutReinitializing() throws {
        let s = try store(directory()); try s.bootstrap()
        let url = s.root.appendingPathComponent("state.json")
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var target = try XCTUnwrap(state["manifest"] as? [String: Any]); target["rootName"] = IntegratedEditorPlan.rootName
        state["manifest"] = target
        try JSONSerialization.data(withJSONObject: state).write(to: url)
        let before = try allFiles(s.root)
        XCTAssertThrowsError(try s.bootstrap())
        XCTAssertEqual(try allFiles(s.root), before)
    }
    func testSessionRestoresUnsentDraftWithoutSeedOverwrite() async throws {
        let base = try directory(), s = try store(base); try s.bootstrap()
        try s.draft(node().id, text: "미저장 합성 초안\n", cursor: .init(location: 3, selectionLength: 0))
        let session = AutoSaveIsolationSession(location: { (AutoSaveIsolationManifest.bundleID, base) })
        await session.open(); XCTAssertTrue(session.opened, session.message)
        session.editor?.updateAutosaveDelay(.seconds(300))
        XCTAssertEqual(session.editor?.currentText, "미저장 합성 초안\n")
        XCTAssertEqual(session.editor?.cursor.location, 3)
        XCTAssertTrue(session.editor?.hasUnsavedChanges ?? false)
        XCTAssertEqual(try s.load(node()), manifest.documents[0].seed)
        XCTAssertEqual(try s.snapshot().drafts[node().id]?.text, "미저장 합성 초안\n")
        await session.save()
    }
    func testSessionSaveSwitchRestartAndDiagnostics() async throws {
        let base = try directory()
        let session = AutoSaveIsolationSession(location: { (AutoSaveIsolationManifest.bundleID, base) })
        await session.open(); XCTAssertTrue(session.opened, session.message)
        let editor = try XCTUnwrap(session.editor)
        editor.updateAutosaveDelay(.seconds(300))
        editor.updateText("붙여넣기\n끝\n", source: .paste)
        session.select(manifest.documents[1].id)
        let s = try store(base)
        XCTAssertEqual(try s.load(node()), manifest.documents[0].seed)
        XCTAssertEqual(try s.snapshot().drafts[node().id]?.text, "붙여넣기\n끝\n")
        XCTAssertEqual(try s.snapshot().diagnostic?.boundary, .documentTransition)
        await session.save(boundary: .saveShortcut)
        XCTAssertEqual(try s.load(node()), "붙여넣기\n끝\n")
        let reopened = AutoSaveIsolationSession(location: { (AutoSaveIsolationManifest.bundleID, base) })
        await reopened.open(); XCTAssertTrue(reopened.opened, reopened.message)
        XCTAssertEqual(reopened.editor?.currentText, "붙여넣기\n끝\n")
        XCTAssertFalse(reopened.editor?.hasUnsavedChanges ?? true)
    }
    func testSessionWrongBundleRemainsClosed() async throws {
        let base = try directory()
        let session = AutoSaveIsolationSession(location: { ("com.chocos.writerpad.debug", base) })
        await session.open()
        XCTAssertFalse(session.opened); XCTAssertNil(session.editor)
        XCTAssertEqual(session.message, AutoSaveIsolationError.bundle.rawValue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path), [])
    }
}

#if WRITERPAD_AUTOSAVE_ISOLATED
@MainActor
final class AutoSaveIsolationBuildTests: XCTestCase {
    func testIsolatedBuildCannotConstructGeneralLiveEnvironment() throws {
        XCTAssertThrowsError(try AppEnvironment.live()) {
            XCTAssertEqual($0 as? AutoSaveIsolationError, .incomplete)
        }
    }
}
#endif
