import Foundation
import XCTest
@testable import SyntheticInitialReceive

final class LocalBoundaryTests: XCTestCase {
    enum Fault: Error { case interrupted, busy }
    final class FakeStorage: LocalBoundaryStorage {
        var value = LocalStorageView(hasUnsentDraft: false, hasUnexpectedData: false)
        var operations: [String] = []
        var fault: String?
        var skip: String?
        var onWrite: (() -> Void)?
        var omitLockBody = false
        var swallowError = false
        private let lock = NSLock()
        func withExclusiveAccess(_ operation: () throws -> Void) throws {
            guard lock.try() else { throw Fault.busy }
            defer { lock.unlock() }
            if omitLockBody { return }
            if swallowError { try? operation() } else { try operation() }
        }
        func read() throws -> LocalStorageView { value }
        func update(_ name: String, _ body: () -> Void) throws {
            operations.append(name)
            if fault == "before:" + name { throw Fault.interrupted }
            if skip != name { body() }
            if fault == "after:" + name { throw Fault.interrupted }
        }
        func bind(_ binding: LocalBoundaryBinding) throws {
            try update("bind") { value.binding = binding; value.phase = .bound }
        }
        func setPhase(_ phase: LocalBoundaryPhase) throws { try update(phase.rawValue) { value.phase = phase } }
        func write(_ data: Data, part: LocalStoragePart) throws {
            try update(part.rawValue) { value.parts[part] = data; onWrite?() }
        }
        func setCompletion(_ digest: String) throws { try update("complete") { value.completionDigest = digest } }
    }

    func fixture() throws -> SyntheticInput {
        func id(_ prefix: String) -> String { prefix + UUID().uuidString.lowercased() }
        let root = id("node-"), a = id("node-"), b = id("node-")
        let nodes: [FixtureManifest.Node] = [
            .init(id: root, kind: "folder", parent: nil, name: "합성경계", path: "합성경계", revision: 2),
            .init(id: a, kind: "document", parent: root, name: "A.txt", path: "합성경계/A.txt", revision: 3),
            .init(id: b, kind: "document", parent: root, name: "B.txt", path: "합성경계/B.txt", revision: 4)]
        let bytes = [a: Data("합성 A\r\n".utf8), b: Data("e\u{301}\n".utf8)]
        let bodies = [a,b].map { FixtureManifest.Body(node: $0, file: "bodies/\($0).txt", bytes: bytes[$0]!.count, sha256: byteHash(bytes[$0]!)) }
        let m = FixtureManifest(version: 1, kind: "synthetic-initial-receive-v1", fixtureID: id("fixture-"), localIdentity: id("local-"), sourceIdentity: id("source-"), root: root,
            expectedNodes: [root,a,b], expectedDocuments: [a,b], expectedOrders: [root], nodes: nodes,
            orders: [.init(parent: root, children: [b,a], revision: 5)], bodies: bodies)
        var files = Dictionary(uniqueKeysWithValues: bodies.map { ($0.file, bytes[$0.node]!) })
        files["manifest.json"] = try canonical(m)
        return try SyntheticInput(files: files)
    }
    func context(_ input: SyntheticInput) throws -> LocalBoundaryContext {
        let ws = URL(fileURLWithPath: try SafeFiles.temporaryPath()).appendingPathComponent("SyntheticInitialReceive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: ws) }
        return LocalBoundaryContext(declaredBundle: LocalBoundaryContext.expectedBundle, syntheticLocalIdentity: input.manifest.localIdentity, workspace: ws)
    }
    func session(_ input: SyntheticInput, _ context: LocalBoundaryContext, _ store: FakeStorage) throws -> LocalBoundarySession {
        try LocalBoundary.prepare(context: context, input: .synthetic(input)) { _ in store }
    }
    func testAllFivePartsAndCapabilitiesStaySeparate() throws {
        let input = try fixture(), ctx = try context(input), store = FakeStorage(), s = try session(input,ctx,store)
        let receipt = try s.apply(), parts = try s.snapshot()
        XCTAssertEqual(Set(parts.keys), Set(LocalStoragePart.allCases))
        let body = try JSONDecoder().decode([String: Data].self, from: parts[.bodies]!)
        XCTAssertEqual(body, input.outputs.filter { $0.key.hasPrefix("tree/") })
        XCTAssertEqual(try JSONDecoder().decode([FixtureManifest.Order].self, from: parts[.treeOrderBaseline]!), input.manifest.orders)
        let result = try JSONSerialization.jsonObject(with: canonical(receipt)) as! [String: Any]
        XCTAssertEqual(result["synthetic_boundary_ready"] as? Bool, true)
        for key in ["baseline_ready","baseline_applied","execution_allowed","app_binding_created","editing_allowed","sending_allowed","automatic_receive_allowed"] {
            XCTAssertEqual(result[key] as? Bool, false)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ctx.workspace.path), [])
    }
    func testWrongBundleAndIdentityBlockBeforeFactory() throws {
        let input = try fixture(), valid = try context(input)
        var calls = 0
        for ctx in [LocalBoundaryContext(declaredBundle: "old.app", syntheticLocalIdentity: input.manifest.localIdentity, workspace: valid.workspace),
                    LocalBoundaryContext(declaredBundle: valid.declaredBundle, syntheticLocalIdentity: UUID().uuidString, workspace: valid.workspace)] {
            XCTAssertThrowsError(try LocalBoundary.prepare(context: ctx, input: .synthetic(input)) { _ in calls += 1; return FakeStorage() })
        }
        XCTAssertEqual(calls,0)
    }
    func testObservationProposalAndRealCandidateBlockBeforeFactory() throws {
        let input = try fixture(), ctx = try context(input)
        var calls = 0
        for value: LocalBoundaryInput in [.observation,.proposal,.realCandidate] {
            XCTAssertThrowsError(try LocalBoundary.prepare(context: ctx,input:value) { _ in calls += 1; return FakeStorage() }) {
                XCTAssertTrue([LocalBoundaryError.unsupportedInput,.realContractUnresolved].contains($0 as? LocalBoundaryError ?? .state))
            }
        }
        XCTAssertEqual(calls,0)
    }
    func testWrongNamespaceAndSymlinkBlockBeforeFactory() throws {
        let input = try fixture(), ctx = try context(input)
        let alias = ctx.workspace.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: ctx.workspace)
        var calls = 0
        for url in [ctx.workspace.appendingPathComponent("Application Support"), alias] {
            let bad = LocalBoundaryContext(declaredBundle: ctx.declaredBundle, syntheticLocalIdentity: ctx.syntheticLocalIdentity, workspace: url)
            XCTAssertThrowsError(try LocalBoundary.prepare(context: bad,input:.synthetic(input)) { _ in calls += 1; return FakeStorage() })
        }
        XCTAssertEqual(calls,0)
    }
    func testUnsentUnknownOrForeignProtectionBlocksWithoutWrites() throws {
        let input = try fixture(), ctx = try context(input)
        for flags: (Bool?,Bool?) in [(true,false),(false,true),(nil,false),(false,nil)] {
            let store = FakeStorage(); store.value.hasUnsentDraft = flags.0; store.value.hasUnexpectedData = flags.1
            let original = store.value, s = try session(input,ctx,store)
            XCTAssertThrowsError(try s.apply()); XCTAssertThrowsError(try s.snapshot())
            XCTAssertEqual(store.value,original); XCTAssertEqual(store.operations,[])
        }
    }
    func testExistingPhysicalStoreOrStoreLinkBlocksBeforeFactory() throws {
        let input = try fixture()
        for isLink in [false,true] {
            let ctx = try context(input), root = ctx.workspace.appendingPathComponent("store")
            let protected = ctx.workspace.appendingPathComponent("protected.txt")
            let bytes = Data("original synthetic neighbor".utf8)
            try bytes.write(to: protected)
            if isLink { try FileManager.default.createSymbolicLink(at: root, withDestinationURL: protected) }
            else {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                try bytes.write(to: root.appendingPathComponent("original.txt"))
            }
            var calls = 0
            XCTAssertThrowsError(try LocalBoundary.prepare(context:ctx,input:.synthetic(input)) { _ in calls += 1; return FakeStorage() })
            XCTAssertEqual(calls,0)
            XCTAssertEqual(try Data(contentsOf:protected),bytes)
            if !isLink { XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("original.txt")),bytes) }
        }
    }
    func testUnboundPartialDataAndMarkerAreNeverAdopted() throws {
        let input = try fixture(), ctx = try context(input)
        for kind in 0..<3 {
            let store = FakeStorage()
            if kind == 0 { store.value.parts[.bodies] = Data("foreign".utf8) }
            if kind == 1 { store.value.phase = .applying }
            if kind == 2 { store.value.completionDigest = "foreign" }
            let before = store.value
            XCTAssertThrowsError(try session(input,ctx,store).apply())
            XCTAssertEqual(store.value,before); XCTAssertEqual(store.operations,[])
        }
    }
    func testSameStoreCannotRebindInputIdentityOrRoot() throws {
        let input = try fixture(), ctx = try context(input), store = FakeStorage()
        try session(input,ctx,store).apply()
        let before = store.value, count = store.operations.count
        let other = try fixture(), otherContext = try context(other)
        XCTAssertThrowsError(try session(other,otherContext,store).apply())
        XCTAssertThrowsError(try session(input,context(input),store).apply())
        XCTAssertEqual(store.value,before); XCTAssertEqual(store.operations.count,count)
    }
    func testEveryBeforeAndAfterWriteResumesInNewSession() throws {
        let input = try fixture(), ctx = try context(input), normal = FakeStorage()
        try session(input,ctx,normal).apply()
        for op in normal.operations {
            for when in ["before:","after:"] {
                let store = FakeStorage(); store.fault = when + op
                let first = try session(input,ctx,store)
                XCTAssertThrowsError(try first.apply(), when + op)
                if store.value.phase != .syntheticReady { XCTAssertThrowsError(try first.snapshot(), when + op) }
                let counts = store.operations.count
                store.fault = nil
                try session(input,ctx,store).apply()
                XCTAssertEqual(try session(input,ctx,store).snapshot(), normal.value.parts)
                if when == "after:" && LocalStoragePart(rawValue:op) != nil {
                    XCTAssertFalse(store.operations.dropFirst(counts).contains(op), "committed part repeated: " + op)
                }
            }
        }
    }
    func testNoOpStorageMethodsNeverReportReady() throws {
        let input = try fixture(), ctx = try context(input)
        for op in ["bind","applying"] + LocalStoragePart.allCases.map(\.rawValue) + ["complete","syntheticReady"] {
            let store = FakeStorage(); store.skip = op
            let s = try session(input,ctx,store)
            XCTAssertThrowsError(try s.apply(),op)
            XCTAssertThrowsError(try s.snapshot(),op)
        }
    }
    func testOmittedLockClosureAndSwallowedFailureCannotSucceed() throws {
        let input = try fixture(), ctx = try context(input)
        let skipped = FakeStorage(); skipped.omitLockBody = true
        let s = try session(input,ctx,skipped)
        XCTAssertThrowsError(try s.apply()); XCTAssertThrowsError(try s.snapshot())
        let swallowed = FakeStorage(); swallowed.swallowError = true; swallowed.fault = "after:bodies"
        let other = try session(input,ctx,swallowed)
        XCTAssertThrowsError(try other.apply()); XCTAssertThrowsError(try other.snapshot())
    }
    func testDraftAppearingDuringWriteStopsRemainingParts() throws {
        let input = try fixture(), ctx = try context(input), store = FakeStorage()
        store.onWrite = { store.value.hasUnsentDraft = true }
        let s = try session(input,ctx,store)
        XCTAssertThrowsError(try s.apply())
        XCTAssertEqual(Set(store.value.parts.keys),[.bodies])
        XCTAssertNil(store.value.completionDigest)
        let before = store.value
        XCTAssertThrowsError(try s.apply()); XCTAssertEqual(store.value,before)
    }
    func testCorruptPartialPartIsPreserved() throws {
        let input = try fixture(), ctx = try context(input), store = FakeStorage()
        store.fault = "after:bodies"
        let s = try session(input,ctx,store)
        XCTAssertThrowsError(try s.apply())
        store.fault = nil; store.value.parts[.bodies] = Data("new unsent body".utf8)
        let before = store.value, count = store.operations.count
        XCTAssertThrowsError(try session(input,ctx,store).apply())
        XCTAssertEqual(store.value,before); XCTAssertEqual(store.operations.count,count)
    }
    func testCompleteStateMissingAnyPartOrMarkerBlocksRepair() throws {
        let input = try fixture(), ctx = try context(input)
        for part in LocalStoragePart.allCases.map(Optional.some) + [nil] {
            let store = FakeStorage(), s = try session(input,ctx,store)
            try s.apply()
            if let part = part { store.value.parts.removeValue(forKey:part) } else { store.value.completionDigest = nil }
            let before = store.value, count = store.operations.count
            XCTAssertThrowsError(try s.snapshot()); XCTAssertThrowsError(try s.apply())
            XCTAssertEqual(store.value,before); XCTAssertEqual(store.operations.count,count)
        }
    }
    func testCorruptCompletePartOrDigestRevokesReadiness() throws {
        let input = try fixture(), ctx = try context(input)
        for part in LocalStoragePart.allCases.map(Optional.some) + [nil] {
            let store = FakeStorage(), s = try session(input,ctx,store)
            try s.apply()
            if let part = part { store.value.parts[part] = Data("changed".utf8) } else { store.value.completionDigest = "wrong" }
            let before = store.value
            XCTAssertThrowsError(try s.snapshot()); XCTAssertThrowsError(try s.apply()); XCTAssertEqual(store.value,before)
        }
    }
    func testCompletedRepeatedCallsDoNotWriteAndLaterDraftBlocks() throws {
        let input = try fixture(), ctx = try context(input), store = FakeStorage(), s = try session(input,ctx,store)
        try s.apply(); let before = store.value, ops = store.operations
        try session(input,ctx,store).apply(); _ = try s.snapshot()
        XCTAssertEqual(store.value,before); XCTAssertEqual(store.operations,ops)
        store.value.hasUnsentDraft = true
        XCTAssertThrowsError(try s.snapshot()); XCTAssertThrowsError(try s.apply())
        XCTAssertEqual(store.operations,ops)
    }
    func testTwoSessionsUseSharedExclusiveStorageLock() throws {
        let input = try fixture(), ctx = try context(input), store = FakeStorage()
        let one = try session(input,ctx,store), two = try session(input,ctx,store)
        var attempted = false
        store.onWrite = {
            if !attempted {
                attempted = true
                do { _ = try two.apply(); XCTFail("second session acquired held lock") }
                catch { XCTAssertTrue(error is Fault) }
            }
        }
        try one.apply(); XCTAssertTrue(attempted)
        XCTAssertEqual(try two.snapshot(),store.value.parts)
    }
    func testBoundStateWithLostPhaseDoesNotReset() throws {
        let input = try fixture(), ctx = try context(input), store = FakeStorage()
        store.fault = "after:bind"
        let s = try session(input,ctx,store)
        XCTAssertThrowsError(try s.apply())
        store.fault = nil; store.value.phase = nil
        let before = store.value
        XCTAssertThrowsError(try s.apply()); XCTAssertEqual(store.value,before)
    }
}
