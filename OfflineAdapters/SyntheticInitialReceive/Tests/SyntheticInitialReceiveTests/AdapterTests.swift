import XCTest
import Foundation
import Darwin
@testable import SyntheticInitialReceive

final class AdapterTests: XCTestCase {
    enum Injected: Error { case stop }
    let fm = FileManager.default

    func workspace() throws -> URL {
        let url = URL(fileURLWithPath: try SafeFiles.temporaryPath()).appendingPathComponent("SyntheticInitialReceive-" + UUID().uuidString)
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? self.fm.removeItem(at: url) }
        return url
    }
    func fixture() throws -> [String: Data] {
        func id(_ prefix: String) -> String { prefix + UUID().uuidString.lowercased() }
        let root = id("node-"), folder = id("node-"), a = id("node-"), b = id("node-")
        let nodes: [FixtureManifest.Node] = [
            .init(id: root, kind: "folder", parent: nil, name: "합성", path: "합성", revision: 1),
            .init(id: folder, kind: "folder", parent: root, name: "chapter", path: "합성/chapter", revision: 2),
            .init(id: a, kind: "document", parent: root, name: "A.txt", path: "합성/A.txt", revision: 3),
            .init(id: b, kind: "document", parent: folder, name: "B.txt", path: "합성/chapter/B.txt", revision: 4)
        ]
        let bytes = [a: Data("합성 A\n".utf8), b: Data("e\u{301}\r\n합성 B\n".utf8)]
        let bodies = [a, b].map { FixtureManifest.Body(node: $0, file: "bodies/\($0).txt", bytes: bytes[$0]!.count, sha256: byteHash(bytes[$0]!)) }
        let manifest = FixtureManifest(version: 1, kind: "synthetic-initial-receive-v1", fixtureID: id("fixture-"), localIdentity: id("local-"), sourceIdentity: id("source-"), root: root,
            expectedNodes: nodes.map(\.id), expectedDocuments: [a, b], expectedOrders: [root, folder], nodes: nodes,
            orders: [.init(parent: root, children: [a, folder], revision: 7), .init(parent: folder, children: [b], revision: 8)], bodies: bodies)
        var files = Dictionary(uniqueKeysWithValues: bodies.map { ($0.file, bytes[$0.node]!) })
        files["manifest.json"] = try canonical(manifest)
        return files
    }
    func mutate(_ files: [String: Data], _ action: (inout FixtureManifest) -> Void) throws -> [String: Data] {
        var files = files, m = try JSONDecoder().decode(FixtureManifest.self, from: files["manifest.json"]!)
        action(&m)
        files["manifest.json"] = try canonical(m)
        return files
    }
    func tree(_ url: URL) throws -> [String: Data] {
        guard fm.fileExists(atPath: url.path) else { return [:] }
        let inventory = try SafeFiles.inventory(url)
        return try Dictionary(uniqueKeysWithValues: inventory.files.map { ($0, try Data(contentsOf: url.appendingPathComponent($0))) })
    }
    func assertRejected(_ files: [String: Data], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SyntheticInput(files: files), file: file, line: line)
    }
    func writeFixture(_ files: [String: Data], into workspace: URL) throws -> URL {
        let root = workspace.appendingPathComponent("fixture")
        for (path, bytes) in files {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        return root
    }
    func crashed(_ input: SyntheticInput, at target: String) throws -> URL {
        let ws = try workspace()
        let adapter = try SyntheticAdapter(workspace: ws) { stage in if stage == target { throw Injected.stop } }
        XCTAssertThrowsError(try adapter.apply(input))
        return ws
    }

    func testExactBytesOrderAndNoRealCapabilities() throws {
        let files = try fixture(), input = try SyntheticInput(files: files)
        let ws = try workspace(), adapter = try SyntheticAdapter(workspace: ws)
        let receipt = try adapter.apply(input), snapshot = try adapter.snapshot(for: input)
        XCTAssertTrue(receipt.synthetic_applied)
        XCTAssertFalse(receipt.baseline_ready || receipt.baseline_applied || receipt.execution_allowed || receipt.app_binding_created)
        let json = try JSONSerialization.jsonObject(with: canonical(receipt)) as! [String: Any]
        for key in ["baseline_ready", "baseline_applied", "execution_allowed", "app_binding_created"] { XCTAssertEqual(json[key] as? Bool, false) }
        for body in input.manifest.bodies {
            let node = input.manifest.nodes.first { $0.id == body.node }!
            XCTAssertEqual(snapshot.files["tree/" + node.path], files[body.file])
        }
        XCTAssertEqual(try JSONDecoder().decode([FixtureManifest.Order].self, from: snapshot.files["orders.json"]!), input.manifest.orders)
        XCTAssertEqual(snapshot.files.count, 5)
    }
    func testCompleteRepeatAndNewInstanceAreByteUnchanged() throws {
        let input = try SyntheticInput(files: fixture()), ws = try workspace()
        let first = try SyntheticAdapter(workspace: ws)
        try first.apply(input)
        let before = try tree(ws)
        try SyntheticAdapter(workspace: ws).apply(input)
        _ = try SyntheticAdapter(workspace: ws).snapshot(for: input)
        XCTAssertEqual(try tree(ws), before)
    }
    func testAllCommittedCheckpointsResumeWithoutPartialReads() throws {
        let input = try SyntheticInput(files: fixture()), reference = try workspace()
        var stages: [String] = []
        try SyntheticAdapter(workspace: reference) { stages.append($0) }.apply(input)
        let selected = stages.filter { ($0.hasPrefix("written:") && $0 != "written:owner.json") || $0.hasPrefix("phase:") }
        XCTAssertGreaterThan(selected.count, 10)
        for stage in selected {
            let ws = try crashed(input, at: stage), adapter = try SyntheticAdapter(workspace: ws)
            if stage != "phase:syntheticApplied" { XCTAssertThrowsError(try adapter.snapshot(for: input), stage) }
            try adapter.apply(input)
            XCTAssertEqual(try adapter.snapshot(for: input).files, input.outputs, stage)
        }
    }
    func testUncommittedPendingFilesBlockAndRemain() throws {
        let input = try SyntheticInput(files: fixture())
        for stage in ["pending:owner.json", "pending:journal.json", "pending:metadata.json", "pending:complete.json"] {
            let ws = try crashed(input, at: stage)
            let before = try unsafeTree(ws)
            XCTAssertThrowsError(try SyntheticAdapter(workspace: ws).apply(input), stage)
            XCTAssertEqual(try unsafeTree(ws), before, stage)
        }
    }
    func unsafeTree(_ url: URL) throws -> [String: Data] {
        // Only for the test's own .pending files, intentionally rejected by the product inventory.
        let names = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])!
        var files: [String: Data] = [:]
        for case let file as URL in names where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            files[String(file.path.dropFirst(url.path.count + 1))] = try Data(contentsOf: file)
        }
        return files
    }
    func testOwnerWithoutJournalCannotBeReconstructed() throws {
        let input = try SyntheticInput(files: fixture()), ws = try crashed(input, at: "written:owner.json")
        let before = try tree(ws)
        XCTAssertThrowsError(try SyntheticAdapter(workspace: ws).apply(input))
        XCTAssertEqual(try tree(ws), before)
    }
    func testDifferentInputAndIdentityCannotRebind() throws {
        let files = try fixture(), input = try SyntheticInput(files: files), ws = try crashed(input, at: "phase:staged")
        let before = try tree(ws)
        for modified in [try fixture(), try mutate(files) { $0.localIdentity = "local-" + UUID().uuidString.lowercased() }, try mutate(files) { $0.orders[0].children.reverse() }] {
            XCTAssertThrowsError(try SyntheticAdapter(workspace: ws).apply(SyntheticInput(files: modified)))
            XCTAssertEqual(try tree(ws), before)
        }
    }
    func testForeignPreexistingFilesArePreserved() throws {
        let ws = try workspace(), store = ws.appendingPathComponent("store")
        try fm.createDirectory(at: store, withIntermediateDirectories: false)
        try Data("foreign draft\n".utf8).write(to: store.appendingPathComponent("draft.txt"))
        let before = try tree(store)
        XCTAssertThrowsError(try SyntheticAdapter(workspace: ws).apply(SyntheticInput(files: fixture())))
        XCTAssertEqual(try tree(store), before)
    }
    func testChangedCompletedBodyMetadataAndOrdersAreNotReplaced() throws {
        for path in ["result/tree/합성/A.txt", "result/metadata.json", "result/orders.json"] {
            let input = try SyntheticInput(files: fixture()), ws = try workspace(), adapter = try SyntheticAdapter(workspace: ws)
            try adapter.apply(input)
            try Data("third-party data".utf8).write(to: adapter.root.appendingPathComponent(path))
            let before = try tree(ws)
            XCTAssertThrowsError(try adapter.snapshot(for: input))
            XCTAssertThrowsError(try adapter.apply(input))
            XCTAssertEqual(try tree(ws), before)
        }
    }
    func testPartialThirdBodyAndCorruptJournalArePreserved() throws {
        let input = try SyntheticInput(files: fixture())
        for path in ["journal.json", "staging/manifest.json", "result/metadata.json"] {
            let ws = try crashed(input, at: "written:result/metadata.json")
            try Data("torn".utf8).write(to: ws.appendingPathComponent("store/" + path))
            let before = try tree(ws)
            XCTAssertThrowsError(try SyntheticAdapter(workspace: ws).apply(input))
            XCTAssertEqual(try tree(ws), before)
        }
    }
    func testMissingCompletedFilesOrMarkerBlock() throws {
        for path in ["complete.json", "journal.json", "result/orders.json", "staging/manifest.json"] {
            let input = try SyntheticInput(files: fixture()), ws = try workspace(), adapter = try SyntheticAdapter(workspace: ws)
            try adapter.apply(input)
            try fm.removeItem(at: adapter.root.appendingPathComponent(path))
            let before = try tree(ws)
            XCTAssertThrowsError(try adapter.apply(input))
            XCTAssertThrowsError(try adapter.snapshot(for: input))
            XCTAssertEqual(try tree(ws), before)
        }
    }
    func testMarkerOnlyAndResultOnlyNeverAdopted() throws {
        for name in ["complete.json", "metadata.json"] {
            let input = try SyntheticInput(files: fixture()), ws = try workspace(), store = ws.appendingPathComponent("store")
            try fm.createDirectory(at: store, withIntermediateDirectories: false)
            try Data("{}\n".utf8).write(to: store.appendingPathComponent(name))
            let before = try tree(store)
            XCTAssertThrowsError(try SyntheticAdapter(workspace: ws).apply(input))
            XCTAssertEqual(try tree(store), before)
        }
    }
    func testUnexpectedExtraFileAndEmptyDirectoryBlock() throws {
        for directory in [false, true] {
            let input = try SyntheticInput(files: fixture()), ws = try workspace(), adapter = try SyntheticAdapter(workspace: ws)
            try adapter.apply(input)
            let extra = adapter.root.appendingPathComponent("unexpected")
            if directory { try fm.createDirectory(at: extra, withIntermediateDirectories: false) }
            else { try Data().write(to: extra) }
            XCTAssertThrowsError(try adapter.apply(input))
            XCTAssertTrue(fm.fileExists(atPath: extra.path))
        }
    }
    func testEmptyFolderIsMaterializedAndRequired() throws {
        let files = try fixture()
        let changed = try mutate(files) { m in
            let id = "node-" + UUID().uuidString.lowercased()
            m.nodes.append(.init(id: id, kind: "folder", parent: m.root, name: "empty", path: "합성/empty", revision: 1))
            m.expectedNodes.append(id); m.expectedOrders.append(id)
            m.orders[0].children.append(id); m.orders.append(.init(parent: id, children: [], revision: 1))
        }
        let input = try SyntheticInput(files: changed), ws = try workspace(), adapter = try SyntheticAdapter(workspace: ws)
        try adapter.apply(input)
        let folder = adapter.root.appendingPathComponent("result/tree/합성/empty")
        XCTAssertTrue(fm.fileExists(atPath: folder.path))
        try fm.removeItem(at: folder)
        XCTAssertThrowsError(try adapter.apply(input))
    }
    func testObservationProposalAndUnknownKeysRejected() throws {
        for kind in ["observation_reviewed", "windows-independent-read-observation-v1", "windows-isolated-target-proposal-v1"] {
            assertRejected(try mutate(fixture()) { $0.kind = kind })
        }
        var files = try fixture()
        var raw = String(data: files["manifest.json"]!, encoding: .utf8)!
        raw = raw.replacingOccurrences(of: "{", with: "{\"execution_allowed\":true,", options: [], range: raw.startIndex..<raw.index(after: raw.startIndex))
        files["manifest.json"] = Data(raw.utf8)
        assertRejected(files)
    }
    func testDuplicateKeysMissingFieldsAndNoncanonicalNumbersRejected() throws {
        let files = try fixture(), raw = String(data: files["manifest.json"]!, encoding: .utf8)!
        for invalid in [raw.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1"), raw.replacingOccurrences(of: "\"version\":1", with: "\"version\":1.0"), raw.replacingOccurrences(of: "\"version\":1", with: "\"version\":true"), raw.replacingOccurrences(of: ",\"version\":1", with: "")] {
            var changed = files; changed["manifest.json"] = Data(invalid.utf8); assertRejected(changed)
        }
    }
    func testRealStyleIdentitiesAndUnknownSchemaRejected() throws {
        for change: (inout FixtureManifest) -> Void in [
            { $0.localIdentity = UUID().uuidString.lowercased() }, { $0.sourceIdentity = "https://example.invalid" },
            { $0.fixtureID = "observation-run" }, { $0.version = 2 }
        ] { assertRejected(try mutate(fixture(), change)) }
    }
    func testMissingBodyExtraFileWrongLengthAndHashRejected() throws {
        let files = try fixture(), input = try SyntheticInput(files: files), path = input.manifest.bodies[0].file
        var missing = files; missing.removeValue(forKey: path); assertRejected(missing)
        var extra = files; extra["extra.txt"] = Data(); assertRejected(extra)
        assertRejected(try mutate(files) { $0.bodies[0].bytes += 1 })
        assertRejected(try mutate(files) { $0.bodies[0].sha256 = String(repeating: "0", count: 64) })
    }
    func testInvalidUTF8EvenWithMatchingHashRejected() throws {
        var files = try fixture()
        let m = try JSONDecoder().decode(FixtureManifest.self, from: files["manifest.json"]!)
        let raw = Data([0xff, 0xfe]); files[m.bodies[0].file] = raw
        files = try mutate(files) { $0.bodies[0].bytes = raw.count; $0.bodies[0].sha256 = byteHash(raw) }
        assertRejected(files)
    }
    func testByteDistinctNewlineAndUnicodeDoNotNormalize() throws {
        let files = try fixture(), input = try SyntheticInput(files: files)
        var changed = files
        let body = input.manifest.bodies[1]
        changed[body.file] = Data("é\n합성 B\n".utf8)
        assertRejected(changed)
    }
    func testPartialDuplicateAndOutOfScopeSetsRejected() throws {
        for change: (inout FixtureManifest) -> Void in [
            { $0.expectedNodes.removeLast() }, { $0.nodes.append($0.nodes[0]) },
            { $0.expectedDocuments.append($0.root) }, { $0.expectedOrders.removeLast() },
            { $0.orders[0].children.append($0.orders[0].children[0]) }, { $0.orders.removeLast() },
            { $0.orders[0].children.append("node-" + UUID().uuidString.lowercased()) }, { $0.bodies.append($0.bodies[0]) }
        ] { assertRejected(try mutate(fixture(), change)) }
    }
    func testParentCycleOrphanDocumentParentAndBadRevisionRejected() throws {
        for change: (inout FixtureManifest) -> Void in [
            { $0.nodes[0].parent = $0.nodes[1].id }, { $0.nodes[1].parent = "node-" + UUID().uuidString.lowercased() },
            { $0.nodes[1].parent = $0.nodes[2].id }, { $0.nodes[1].parent = nil },
            { $0.nodes[0].revision = 0 }, { $0.orders[0].revision = -1 }
        ] { assertRejected(try mutate(fixture(), change)) }
    }
    func testTraversalAliasesAndPathMismatchRejected() throws {
        for name in ["..", "../a", "a\\b", "a:b", "a\u{0}", "a ", "a.", "a.pending"] {
            assertRejected(try mutate(fixture()) { $0.nodes[2].name = name; $0.nodes[2].path = "합성/" + name })
        }
        assertRejected(try mutate(fixture()) { $0.nodes[2].path = "wrong/A.txt" })
        assertRejected(try mutate(fixture()) { m in m.nodes[3].parent = m.root; m.nodes[3].name = "a.TXT"; m.nodes[3].path = "합성/a.TXT" })
    }
    func testUnicodeCanonicalNameCollisionRejected() throws {
        assertRejected(try mutate(fixture()) { m in
            m.nodes[2].name = "é.txt"; m.nodes[2].path = "합성/é.txt"
            m.nodes[3].parent = m.root; m.nodes[3].name = "e\u{301}.txt"; m.nodes[3].path = "합성/e\u{301}.txt"
        })
    }
    func testInputSizeBoundBeforeDecoding() throws {
        var files = try fixture()
        files["large"] = Data(repeating: 0, count: 4 * 1024 * 1024 + 1)
        assertRejected(files)
    }
    func testFixtureDirectoryReadOnlyAndNeighborPreserved() throws {
        let ws = try workspace(), files = try fixture(), directory = try writeFixture(files, into: ws)
        try Data("protected unsent synthetic draft".utf8).write(to: ws.appendingPathComponent("protected.txt"))
        let before = try tree(directory), protected = try Data(contentsOf: ws.appendingPathComponent("protected.txt"))
        let input = try SyntheticInput.load(directory: directory)
        try SyntheticAdapter(workspace: ws).apply(input)
        XCTAssertEqual(try tree(directory), before)
        XCTAssertEqual(try Data(contentsOf: ws.appendingPathComponent("protected.txt")), protected)
    }
    func testWorkspaceOutsideDisposableNamespaceRejectedWithoutWrites() throws {
        let ws = try workspace()
        let bad = ws.appendingPathComponent("Application Support")
        try fm.createDirectory(at: bad, withIntermediateDirectories: false)
        XCTAssertThrowsError(try SyntheticAdapter(workspace: bad))
        XCTAssertEqual(try tree(ws), [:])
    }
    func testInputStoreAndLockSymlinksRejected() throws {
        for target in ["store", "store.lock", "fixture/manifest.json"] {
            let ws = try workspace(), files = try fixture(), directory = try writeFixture(files, into: ws)
            let outside = ws.appendingPathComponent("protected")
            try Data("protected".utf8).write(to: outside)
            let link = ws.appendingPathComponent(target)
            if fm.fileExists(atPath: link.path) { try fm.removeItem(at: link) }
            try fm.createSymbolicLink(at: link, withDestinationURL: outside)
            if target.hasPrefix("fixture") { XCTAssertThrowsError(try SyntheticInput.load(directory: directory)) }
            else { XCTAssertThrowsError(try SyntheticAdapter(workspace: ws).apply(SyntheticInput(files: files))) }
            XCTAssertEqual(try Data(contentsOf: outside), Data("protected".utf8))
        }
    }
    func testHardlinkedBodyRejectedAndOriginalPreserved() throws {
        let ws = try workspace(), files = try fixture(), directory = try writeFixture(files, into: ws)
        let file = directory.appendingPathComponent(try SyntheticInput(files: files).manifest.bodies[0].file)
        let before = try Data(contentsOf: file)
        try fm.linkItem(at: file, to: ws.appendingPathComponent("hardlink"))
        XCTAssertThrowsError(try SyntheticInput.load(directory: directory))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testTwoInstancesCannotWriteConcurrently() throws {
        let ws = try workspace(), input = try SyntheticInput(files: fixture())
        let second = try SyntheticAdapter(workspace: ws)
        var checked = false
        let first = try SyntheticAdapter(workspace: ws) { stage in
            if stage == "locked" {
                XCTAssertThrowsError(try second.apply(input)) { XCTAssertEqual($0 as? ReceiveError, .busy) }
                checked = true
            }
        }
        try first.apply(input)
        XCTAssertTrue(checked)
    }

    func probe() throws -> URL {
        var parent = Bundle(for: AdapterTests.self).bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let url = parent.appendingPathComponent("SyntheticReceiveProbe")
            if fm.isExecutableFile(atPath: url.path) { return url }
            parent.deleteLastPathComponent()
        }
        throw ReceiveError.incomplete
    }
    func launch(_ ws: URL, _ fixture: URL, _ stage: String, _ mode: String) throws -> (Process, Pipe, Pipe, Pipe) {
        let process = Process(), output = Pipe(), error = Pipe(), input = Pipe()
        process.executableURL = try probe()
        process.arguments = [ws.path, fixture.path, stage, mode]
        process.standardOutput = output; process.standardError = error; process.standardInput = input
        try process.run()
        addTeardownBlock { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        return (process, output, error, input)
    }
    func wait(_ process: Process) {
        let done = expectation(description: "subprocess exit")
        process.terminationHandler = { _ in done.fulfill() }
        if !process.isRunning { process.terminationHandler = nil; done.fulfill() }
        wait(for: [done], timeout: 10)
    }
    func testAbruptProcessExitReleasesLockAndResumes() throws {
        for stage in ["written:journal.json", "phase:staged", "written:result/metadata.json", "written:complete.json", "phase:syntheticApplied"] {
            let ws = try workspace(), files = try fixture(), directory = try writeFixture(files, into: ws)
            let (process, _, error, _) = try launch(ws, directory, stage, "crash")
            wait(process)
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            let report = try JSONSerialization.jsonObject(with: errorData) as! [String: String]
            XCTAssertEqual(process.terminationStatus, 73)
            XCTAssertEqual(report["checkpoint"], stage)
            XCTAssertEqual(report["reason"], "injected-process-exit-73")
            print("EXPECTED PROCESS INTERRUPTION: " + String(data: errorData, encoding: .utf8)!)
            let next = try SyntheticAdapter(workspace: ws), input = try SyntheticInput(files: files)
            try next.apply(input)
            XCTAssertEqual(try next.snapshot(for: input).files, input.outputs)
        }
    }
    func testSeparateProcessLockContentionAndTermination() throws {
        let ws = try workspace(), files = try fixture(), directory = try writeFixture(files, into: ws)
        let (process, output, _, inputPipe) = try launch(ws, directory, "locked", "hold")
        let data = try output.fileHandleForReading.read(upToCount: 7)
        XCTAssertEqual(data, Data("LOCKED\n".utf8))
        let adapter = try SyntheticAdapter(workspace: ws), input = try SyntheticInput(files: files)
        XCTAssertThrowsError(try adapter.apply(input)) { XCTAssertEqual($0 as? ReceiveError, .busy) }
        XCTAssertFalse(fm.fileExists(atPath: adapter.root.path))
        process.terminate(); wait(process)
        try inputPipe.fileHandleForWriting.close()
        try adapter.apply(input)
        XCTAssertTrue(try adapter.snapshot(for: input).receipt.synthetic_applied)
    }

    func testSubprocessFailureReportDoesNotRepairCorruptStore() throws {
        let ws = try workspace(), files = try fixture(), directory = try writeFixture(files, into: ws)
        let input = try SyntheticInput(files: files), adapter = try SyntheticAdapter(workspace: ws)
        try adapter.apply(input)
        try Data("damaged".utf8).write(to: adapter.root.appendingPathComponent("journal.json"))
        let before = try tree(ws)
        let (process, _, error, _) = try launch(ws, directory, "", "apply")
        wait(process)
        XCTAssertEqual(process.terminationStatus, 1)
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        let report = try JSONSerialization.jsonObject(with: errorData) as! [String: String]
        XCTAssertEqual(report["kind"], "synthetic-host-failure")
        XCTAssertEqual(report["checkpoint"], "locked")
        XCTAssertEqual(report["reason"], "schema")
        XCTAssertEqual(try tree(ws), before)
        print("EXPECTED REJECTION: " + String(data: errorData, encoding: .utf8)!)
    }
}
