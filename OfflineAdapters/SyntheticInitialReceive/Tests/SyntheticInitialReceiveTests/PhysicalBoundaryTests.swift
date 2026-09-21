import Foundation
import XCTest
import Darwin
@testable import SyntheticInitialReceive

final class PhysicalBoundaryTests: XCTestCase {
    enum Injected: Error { case stop }
    let fm = FileManager.default

    func fixture() throws -> SyntheticInput {
        func id(_ prefix: String) -> String { prefix + UUID().uuidString.lowercased() }
        let root = id("node-"), a = id("node-"), b = id("node-")
        let nodes: [FixtureManifest.Node] = [
            .init(id: root, kind: "folder", parent: nil, name: "물리합성", path: "물리합성", revision: 2),
            .init(id: a, kind: "document", parent: root, name: "A.txt", path: "물리합성/A.txt", revision: 3),
            .init(id: b, kind: "document", parent: root, name: "B.txt", path: "물리합성/B.txt", revision: 4)]
        let bytes = [a: Data("e\u{301}🙂\r\n".utf8), b: Data()]
        let bodies = [a,b].map { FixtureManifest.Body(node: $0, file: "bodies/\($0).txt", bytes: bytes[$0]!.count, sha256: byteHash(bytes[$0]!)) }
        let manifest = FixtureManifest(version: 1, kind: "synthetic-initial-receive-v1", fixtureID: id("fixture-"),
            localIdentity: id("local-"), sourceIdentity: id("source-"), root: root, expectedNodes: [root,a,b],
            expectedDocuments: [a,b], expectedOrders: [root], nodes: nodes,
            orders: [.init(parent: root, children: [b,a], revision: 8)], bodies: bodies)
        var files = Dictionary(uniqueKeysWithValues: bodies.map { ($0.file, bytes[$0.node]!) })
        files["manifest.json"] = try canonical(manifest)
        return try SyntheticInput(files: files)
    }
    func workspace() throws -> URL {
        let ws = URL(fileURLWithPath: try SafeFiles.temporaryPath()).appendingPathComponent("SyntheticInitialReceive-" + UUID().uuidString)
        try fm.createDirectory(at: ws, withIntermediateDirectories: false)
        addTeardownBlock { try? self.fm.removeItem(at: ws) }
        return ws
    }
    func context(_ input: SyntheticInput, _ ws: URL) -> LocalBoundaryContext {
        LocalBoundaryContext(declaredBundle: LocalBoundaryContext.expectedBundle, syntheticLocalIdentity: input.manifest.localIdentity, workspace: ws)
    }
    func session(_ input: SyntheticInput, _ ws: URL, stop: String? = nil) throws -> LocalBoundarySession {
        try LocalBoundary.preparePhysical(context: context(input,ws), input: .synthetic(input)) { stage in
            if stage == stop { throw Injected.stop }
        }
    }
    func root(_ ws: URL) -> URL { ws.appendingPathComponent("physical-boundary") }
    func tree(_ ws: URL) throws -> [String: Data] {
        if !fm.fileExists(atPath: ws.path) { return [:] }
        // Evidence snapshots must include .pending files that the production reader rejects.
        var result: [String:Data] = [:]
        func visit(_ directory: URL, _ prefix: String) throws {
            for name in try fm.contentsOfDirectory(atPath:directory.path) {
                let url = directory.appendingPathComponent(name)
                guard let attr = try SafeFiles.attributes(url) else { throw ReceiveError.io }
                if attr.st_mode & S_IFMT == S_IFDIR { try visit(url,prefix + name + "/") }
                else { result[prefix + name] = try SafeFiles.read(url) }
            }
        }
        try visit(ws,"")
        return result
    }
    func rawFixture(_ input: SyntheticInput, _ ws: URL) throws -> URL {
        let directory = ws.appendingPathComponent("fixture")
        for (name,data) in input.sourceFiles {
            let file = directory.appendingPathComponent(name)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        return directory
    }
    func assertBlockedUnchanged(_ input: SyntheticInput, _ ws: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try tree(root(ws)), s = try session(input,ws)
        XCTAssertThrowsError(try s.snapshot(),file:file,line:line)
        XCTAssertThrowsError(try s.apply(),file:file,line:line)
        XCTAssertEqual(try tree(root(ws)),before,file:file,line:line)
    }

    func testFiveFilesExactBytesAndSeparateCompletionWithAllRealFlagsFalse() throws {
        let input = try fixture(), ws = try workspace(), s = try session(input,ws)
        XCTAssertEqual(try tree(ws),[:]) // prepare has no physical side effects
        XCTAssertThrowsError(try s.snapshot())
        let result = try s.apply(), data = try s.snapshot()
        XCTAssertEqual(Set(data.keys),Set(LocalStoragePart.allCases))
        XCTAssertEqual(try JSONDecoder().decode([String:Data].self,from:data[.bodies]!),input.outputs.filter { $0.key.hasPrefix("tree/") })
        XCTAssertEqual(try JSONDecoder().decode([FixtureManifest.Order].self,from:data[.treeOrderBaseline]!),input.manifest.orders)
        XCTAssertEqual(try tree(root(ws)).count,15) // 5 payloads + 9 records + head
        let json = try JSONSerialization.jsonObject(with: canonical(result)) as! [String:Any]
        XCTAssertEqual(json["synthetic_boundary_ready"] as? Bool,true)
        for key in ["baseline_ready","baseline_applied","execution_allowed","app_binding_created","editing_allowed","sending_allowed","automatic_receive_allowed"] {
            XCTAssertEqual(json[key] as? Bool,false)
        }
        XCTAssertFalse(fm.fileExists(atPath: ws.appendingPathComponent("store").path))
    }

    func testNewInstanceRepeatedApplyAndSnapshotDoNotRewriteFiles() throws {
        let input = try fixture(), ws = try workspace()
        try session(input,ws).apply(); let before = try tree(ws)
        var modified: [String:Date] = [:]
        for name in before.keys { modified[name] = try fm.attributesOfItem(atPath: ws.appendingPathComponent(name).path)[.modificationDate] as? Date }
        try session(input,ws).apply(); _ = try session(input,ws).snapshot()
        XCTAssertEqual(try tree(ws),before)
        for (name,date) in modified { XCTAssertEqual(try fm.attributesOfItem(atPath: ws.appendingPathComponent(name).path)[.modificationDate] as? Date,date) }
    }

    func testAllNinePublishedCommitsResumeWithoutPrematureSnapshots() throws {
        let input = try fixture()
        for sequence in 1...9 {
            let ws = try workspace(), s = try session(input,ws,stop:"committed:\(sequence)")
            XCTAssertThrowsError(try s.apply())
            let committed = try tree(root(ws))
            if sequence < 9 { XCTAssertThrowsError(try session(input,ws).snapshot()) }
            else { XCTAssertEqual(try session(input,ws).snapshot().count,5) }
            try session(input,ws).apply()
            let after = try tree(root(ws))
            for (name,data) in committed where name != "head.json" { XCTAssertEqual(after[name],data) }
            XCTAssertEqual(try session(input,ws).snapshot().count,5)
        }
    }

    func testBeforeEachNewPartWriteIsRetryableFromCommittedHead() throws {
        let input = try fixture()
        for part in LocalStoragePart.allCases {
            let ws = try workspace()
            XCTAssertThrowsError(try session(input,ws,stop:"before:part-\(part.rawValue).bin").apply())
            XCTAssertThrowsError(try session(input,ws).snapshot())
            try session(input,ws).apply()
            XCTAssertEqual(try session(input,ws).snapshot().count,5)
        }
    }

    func testPendingPartsRecordHeadAndEmptyRootPreservedAndBlocked() throws {
        let input = try fixture()
        for stage in ["created-root","pending:record-01.json","pending:head.json","pending:part-bodies.bin",
                      "written:part-bodies.bin","written:record-03.json","pending:record-08.json","written:record-09.json"] {
            let ws = try workspace()
            XCTAssertThrowsError(try session(input,ws,stop:stage).apply(),stage)
            try assertBlockedUnchanged(input,ws)
        }
    }

    func testEveryPendingPayloadIsBlockedWithoutGuessingItsHash() throws {
        let input = try fixture()
        for part in LocalStoragePart.allCases {
            let ws = try workspace()
            XCTAssertThrowsError(try session(input,ws,stop:"pending:part-\(part.rawValue).bin").apply())
            try assertBlockedUnchanged(input,ws)
        }
    }

    func testMissingOrCorruptEveryCompletedPayloadBlocksWithoutRepair() throws {
        let input = try fixture()
        for part in LocalStoragePart.allCases {
            for missing in [true,false] {
                let ws = try workspace();try session(input,ws).apply()
                let url = root(ws).appendingPathComponent("part-\(part.rawValue).bin")
                if missing { try fm.removeItem(at:url) } else { try Data("changed synthetic draft".utf8).write(to:url) }
                try assertBlockedUnchanged(input,ws)
            }
        }
    }

    func testCorruptPartialPayloadCannotBecomeReadyOnRestart() throws {
        let input = try fixture(), ws = try workspace()
        XCTAssertThrowsError(try session(input,ws,stop:"committed:3").apply())
        try Data("unsent synthetic change".utf8).write(to:root(ws).appendingPathComponent("part-bodies.bin"))
        try assertBlockedUnchanged(input,ws)
    }

    func testMissingHeadOrAnyJournalRecordIsNeverAutoInitialized() throws {
        let input = try fixture()
        for name in ["head.json"] + (1...9).map({ String(format:"record-%02d.json",$0) }) {
            let ws = try workspace();try session(input,ws).apply()
            try fm.removeItem(at:root(ws).appendingPathComponent(name))
            try assertBlockedUnchanged(input,ws)
        }
    }

    func testHeadHashAndChainTamperFailClosed() throws {
        let input = try fixture()
        for name in ["head.json","record-03.json","record-09.json"] {
            let ws = try workspace();try session(input,ws).apply()
            try Data("{}\n".utf8).write(to:root(ws).appendingPathComponent(name))
            try assertBlockedUnchanged(input,ws)
        }
    }

    func testForeignDraftDirectoryOrExtraRecordRevokesCompletedReadiness() throws {
        let input = try fixture()
        for name in ["draft.txt","record-10.json","unexpected"] {
            let ws = try workspace();try session(input,ws).apply()
            if name == "unexpected" { try fm.createDirectory(at:root(ws).appendingPathComponent(name),withIntermediateDirectories:false) }
            else { try Data("protected neighbor".utf8).write(to:root(ws).appendingPathComponent(name)) }
            try assertBlockedUnchanged(input,ws)
        }
    }

    func testExistingUnownedEmptyOrPopulatedRootNotAdopted() throws {
        let input = try fixture()
        for populated in [false,true] {
            let ws = try workspace();try fm.createDirectory(at:root(ws),withIntermediateDirectories:false)
            if populated { try Data("foreign".utf8).write(to:root(ws).appendingPathComponent("original.txt")) }
            try assertBlockedUnchanged(input,ws)
        }
    }

    func testWrongIdentityFixtureAndCopiedStoreAtOtherRootRejected() throws {
        let input = try fixture(), other = try fixture(), ws = try workspace()
        try session(input,ws).apply();let before = try tree(root(ws))
        XCTAssertThrowsError(try session(other,ws).apply());XCTAssertEqual(try tree(root(ws)),before)
        let elsewhere = try workspace();try fm.copyItem(at:root(ws),to:root(elsewhere))
        try assertBlockedUnchanged(input,elsewhere)
        XCTAssertEqual(try tree(root(ws)),before)
    }

    func testWrongBundleRealInputAndNonTemporaryNamespaceDoNotCreateStorage() throws {
        let input = try fixture(), ws = try workspace()
        for value: LocalBoundaryInput in [.observation,.proposal,.realCandidate] {
            XCTAssertThrowsError(try LocalBoundary.preparePhysical(context:context(input,ws),input:value))
        }
        let bad = LocalBoundaryContext(declaredBundle:"old.app",syntheticLocalIdentity:input.manifest.localIdentity,workspace:ws)
        XCTAssertThrowsError(try LocalBoundary.preparePhysical(context:bad,input:.synthetic(input)))
        let wrong = LocalBoundaryContext(declaredBundle:LocalBoundaryContext.expectedBundle,syntheticLocalIdentity:"local-wrong",workspace:ws)
        XCTAssertThrowsError(try LocalBoundary.preparePhysical(context:wrong,input:.synthetic(input)))
        XCTAssertThrowsError(try session(input,ws.appendingPathComponent("Application Support")))
        XCTAssertEqual(try tree(ws),[:])
    }

    func testLegacyStorePreservedBeforePreparationAndAfterPreparation() throws {
        let input = try fixture()
        for delayed in [false,true] {
            let ws = try workspace(), s = delayed ? try session(input,ws) : nil
            try SyntheticAdapter(workspace:ws).apply(input);let before = try tree(ws)
            if let s = s { XCTAssertThrowsError(try s.apply()) }
            else { XCTAssertThrowsError(try session(input,ws)) }
            XCTAssertEqual(try tree(ws),before)
        }
    }

    func testSymlinkAndHardlinkStoreLockOrPayloadRejectedWithoutTouchingNeighbor() throws {
        let input = try fixture()
        for name in ["physical-boundary","physical-boundary.lock","physical-boundary/part-bodies.bin"] {
            for hard in [false,true] {
                let ws = try workspace()
                if name.contains("/part-") { try session(input,ws).apply() }
                let neighbor = ws.appendingPathComponent("neighbor.txt"), bytes = Data("protected synthetic original".utf8)
                try bytes.write(to:neighbor)
                let link = ws.appendingPathComponent(name)
                if fm.fileExists(atPath:link.path) { try fm.removeItem(at:link) }
                if hard { try fm.linkItem(at:neighbor,to:link) }
                else { try fm.createSymbolicLink(at:link,withDestinationURL:neighbor) }
                XCTAssertThrowsError(try session(input,ws).apply())
                XCTAssertEqual(try Data(contentsOf:neighbor),bytes)
                XCTAssertNotNil(try SafeFiles.attributes(link))
            }
        }
    }

    func testSourceFilesAndUnsentSyntheticNeighborsRemainByteIdentical() throws {
        let input = try fixture(), ws = try workspace(), directory = try rawFixture(input,ws)
        let a = ws.appendingPathComponent("unsent-a.txt"), b = ws.appendingPathComponent("unsent-b.txt")
        try Data(repeating:65,count:18).write(to:a);try Data(repeating:66,count:19).write(to:b)
        let before = try tree(directory)
        try session(SyntheticInput.load(directory:directory),ws).apply()
        XCTAssertEqual(try tree(directory),before)
        XCTAssertEqual(try Data(contentsOf:a),Data(repeating:65,count:18));XCTAssertEqual(try Data(contentsOf:b),Data(repeating:66,count:19))
    }

    func testStorageProtocolRequiresLockAndRejectsOutOfOrderMutations() throws {
        let input = try fixture(), ws = try workspace(), s = try session(input,ws)
        let store = try PhysicalBoundaryStorage(workspace:ws,binding:s.binding)
        XCTAssertThrowsError(try store.read());XCTAssertThrowsError(try store.bind(s.binding))
        try store.withExclusiveAccess {
            XCTAssertThrowsError(try store.setPhase(.syntheticReady))
            try store.bind(s.binding)
            XCTAssertThrowsError(try store.write(Data(),part:.bodies))
            XCTAssertThrowsError(try store.setCompletion(s.binding.resultDigest))
            try store.setPhase(.applying)
            XCTAssertThrowsError(try store.write(Data(),part:.metadata))
        }
        XCTAssertThrowsError(try store.read())
        try s.apply();XCTAssertEqual(try s.snapshot().count,5)
    }

    func testTwoInstancesAndReentrantAccessCannotShareHeldLock() throws {
        let input = try fixture(), ws = try workspace(), other = try session(input,ws)
        var seen = false
        let first = try LocalBoundary.preparePhysical(context:context(input,ws),input:.synthetic(input)) { stage in
            if stage == "locked" {
                seen = true
                XCTAssertThrowsError(try other.apply()) { XCTAssertEqual($0 as? ReceiveError,.busy) }
            }
        }
        try first.apply();XCTAssertTrue(seen)
        let store = try PhysicalBoundaryStorage(workspace:ws,binding:first.binding)
        try store.withExclusiveAccess { XCTAssertThrowsError(try store.withExclusiveAccess {}) }
    }

    func testDifferentThreadCannotBorrowAnotherThreadsHeldLock() throws {
        let input = try fixture(), ws = try workspace(), s = try session(input,ws)
        let store = try PhysicalBoundaryStorage(workspace:ws,binding:s.binding)
        let rejected = expectation(description:"foreign thread read rejected")
        try store.withExclusiveAccess {
            DispatchQueue.global().async {
                do { _ = try store.read(); XCTFail("foreign thread used another thread's lock") }
                catch { XCTAssertEqual(error as? PhysicalStorageError,.lockRequired) }
                rejected.fulfill()
            }
            wait(for:[rejected],timeout:2)
            try store.bind(s.binding)
        }
        try s.apply()
    }

    func testOldStoreAppearingWhileLockedBlocksSubsequentWrites() throws {
        let input = try fixture(), ws = try workspace()
        let s = try LocalBoundary.preparePhysical(context:context(input,ws),input:.synthetic(input)) { stage in
            if stage == "committed:3" {
                let legacy = ws.appendingPathComponent("store")
                try self.fm.createDirectory(at:legacy,withIntermediateDirectories:false)
                try Data("protected synthetic old data".utf8).write(to:legacy.appendingPathComponent("original.txt"))
            }
        }
        XCTAssertThrowsError(try s.apply())
        let before = try tree(ws)
        XCTAssertFalse(fm.fileExists(atPath:root(ws).appendingPathComponent("part-metadata.bin").path))
        XCTAssertThrowsError(try s.snapshot());XCTAssertThrowsError(try s.apply())
        XCTAssertEqual(try tree(ws),before)
    }

    func probe() throws -> URL {
        var directory = Bundle(for:PhysicalBoundaryTests.self).bundleURL
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("PhysicalBoundaryProbe")
            if fm.isExecutableFile(atPath:candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw ReceiveError.io
    }
    func launch(_ ws:URL,_ fixture:URL,_ checkpoint:String,_ mode:String) throws -> (Process,Pipe,Pipe,Pipe) {
        let p = Process(), output = Pipe(), error = Pipe(), input = Pipe()
        p.executableURL = try probe();p.arguments = [ws.path,fixture.path,checkpoint,mode]
        p.standardOutput = output;p.standardError = error;p.standardInput = input
        try p.run()
        return (p,output,error,input)
    }
    func wait(_ p:Process) {
        let end = Date().addingTimeInterval(8)
        while p.isRunning && Date() < end { Thread.sleep(forTimeInterval:0.01) }
        if p.isRunning { kill(p.processIdentifier,SIGKILL);XCTFail("host probe timeout") }
        p.waitUntilExit()
    }

    func testSeparateProcessExitAtEachCommittedStageCanReopenAndResume() throws {
        let input = try fixture()
        for sequence in 1...9 {
            let ws = try workspace(), directory = try rawFixture(input,ws)
            let (p,_,error,_) = try launch(ws,directory,"committed:\(sequence)","crash")
            wait(p);XCTAssertEqual(p.terminationStatus,73)
            let report = error.fileHandleForReading.readDataToEndOfFile()
            XCTAssertTrue(String(decoding:report,as:UTF8.self).contains("synthetic-exit-73"))
            if sequence < 9 { XCTAssertThrowsError(try session(input,ws).snapshot()) }
            let (resumed,output,_,_) = try launch(ws,directory,"","apply")
            wait(resumed);XCTAssertEqual(resumed.terminationStatus,0)
            let receipt = try JSONSerialization.jsonObject(with:output.fileHandleForReading.readDataToEndOfFile()) as! [String:Any]
            XCTAssertEqual(receipt["synthetic_boundary_ready"] as? Bool,true)
            XCTAssertEqual(receipt["baseline_applied"] as? Bool,false)
            XCTAssertEqual(try session(input,ws).snapshot().count,5)
            print("PHYSICAL PROCESS RESUME: committed:\(sequence), exit=73, resumed=0")
        }
    }

    func testSeparateProcessExitWithPendingOrOrphanEvidenceRemainsBlocked() throws {
        let input = try fixture()
        for checkpoint in ["created-root","pending:record-01.json","pending:head.json","pending:part-bodies.bin","written:part-bodies.bin","written:record-09.json"] {
            let ws = try workspace(), directory = try rawFixture(input,ws)
            let (p,_,_,_) = try launch(ws,directory,checkpoint,"crash")
            wait(p);XCTAssertEqual(p.terminationStatus,73)
            let before = try tree(root(ws))
            let (blocked,_,_,_) = try launch(ws,directory,"","apply")
            wait(blocked);XCTAssertEqual(blocked.terminationStatus,1)
            XCTAssertEqual(try tree(root(ws)),before)
            XCTAssertThrowsError(try session(input,ws).snapshot())
            print("PHYSICAL PROCESS BLOCK: \(checkpoint), exit=73, retry=1, unchanged=true")
        }
    }

    func testSeparateProcessHeldLockRejectsContenderAndKillReleasesIt() throws {
        let input = try fixture(), ws = try workspace(), directory = try rawFixture(input,ws)
        let (holder,output,_,_) = try launch(ws,directory,"committed:3","hold")
        defer { if holder.isRunning { kill(holder.processIdentifier,SIGKILL);holder.waitUntilExit() } }
        let data = try output.fileHandleForReading.read(upToCount:7)
        XCTAssertEqual(data,Data("LOCKED\n".utf8))
        XCTAssertThrowsError(try session(input,ws).apply()) { XCTAssertEqual($0 as? ReceiveError,.busy) }
        kill(holder.processIdentifier,SIGKILL);wait(holder)
        XCTAssertEqual(holder.terminationReason,.uncaughtSignal)
        XCTAssertThrowsError(try session(input,ws).snapshot())
        try session(input,ws).apply();XCTAssertEqual(try session(input,ws).snapshot().count,5)
    }
}
