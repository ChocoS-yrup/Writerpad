import Foundation
import XCTest
import Darwin
@testable import SyntheticInitialReceive

final class SyntheticABDiskJournalTests: XCTestCase {
    enum Injected: Error { case stop }
    let fm = FileManager.default
    let runID = "synthetic-ab-ee260914-0000-4000-8000-000000009200"
    func workspace() throws -> URL {
        let url = URL(fileURLWithPath:try SafeFiles.temporaryPath()).appendingPathComponent("SyntheticABJournal-"+UUID().uuidString.lowercased())
        try fm.createDirectory(at:url,withIntermediateDirectories:false)
        addTeardownBlock { try? self.fm.removeItem(at:url) }
        return url
    }
    func root(_ ws: URL) -> URL { ws.appendingPathComponent("execution-journal") }
    func snapshot(_ ws: URL) throws -> [String:Data] {
        guard fm.fileExists(atPath:root(ws).path) else { return [:] }
        var values: [String:Data] = [:]
        for name in try fm.contentsOfDirectory(atPath:root(ws).path) {
            let url = root(ws).appendingPathComponent(name)
            if let a = try SafeFiles.attributes(url), a.st_mode & S_IFMT == S_IFREG { values[name] = try Data(contentsOf:url) }
        }
        return values
    }
    func runner(_ id: String? = nil) throws -> SyntheticABRunner { try .init(expected:.fixture(),timing:.fixture,runID:id ?? runID) }
    func transport() -> SyntheticABTransport { let e = SyntheticABExpected.fixture(); return .init(e.responses()+e.responses()) }
    @discardableResult func execute(_ disk: SyntheticABDiskJournal,_ transport: SyntheticABTransport? = nil,_ journal: SyntheticABJournal? = nil,_ delays: SyntheticABDelays = .init()) throws -> SyntheticABCompletion {
        try runner().run(transport:transport ?? self.transport(),journal:journal ?? SyntheticABJournal(disk:disk),environment:SyntheticABEnvironment(),delays:delays)
    }
    func blocked(_ ws: URL,file: StaticString = #filePath,line: UInt = #line) throws {
        let before = try snapshot(ws), transport = self.transport()
        XCTAssertThrowsError(try execute(SyntheticABDiskJournal(workspace:ws),transport),file:file,line:line)
        XCTAssertTrue(transport.calls.isEmpty,file:file,line:line)
        XCTAssertEqual(try snapshot(ws),before,file:file,line:line)
    }
    func stop(_ disk: SyntheticABDiskJournal,at point: String) { disk.checkpoint = { if $0 == point { throw Injected.stop } } }

    func testCompletePersistsFourteenReservationsRawHashesAndClosedAuthority() throws {
        let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws), transport = self.transport()
        let completion = try execute(disk,transport), report = try completion.checkedReport()
        let state = try SyntheticABDiskJournal(workspace:ws).read()
        XCTAssertEqual(state.httpUsed,14); XCTAssertEqual(state.authUsed,2); XCTAssertEqual(state.status,"finished")
        XCTAssertEqual(state.events.count,15); XCTAssertEqual(transport.calls.count,14)
        XCTAssertEqual(state.context?.timing,.fixture); XCTAssertEqual(state.context?.sessionExpiresUTCMS,6000)
        XCTAssertEqual(state.context?.startedUTCMS,1000); XCTAssertEqual(state.context?.startedMonoMS,0)
        XCTAssertEqual(state.context?.journalBinding,state.binding)
        for e in state.events.prefix(14) { XCTAssertEqual(e.sha256,byteHash(try XCTUnwrap(e.raw))); XCTAssertEqual(e.byteCount,e.raw?.count) }
        XCTAssertEqual(try snapshot(ws).count,63) // 60 snapshots (genesis + claim + 56 request stages + probe + finish) + owner/head/lock.
        XCTAssertFalse(report.baseline_ready); XCTAssertFalse(report.baseline_applied); XCTAssertFalse(report.execution_allowed)
        XCTAssertFalse(report.app_binding_created); XCTAssertThrowsError(try completion.requireApplyInput())
        XCTAssertEqual(try SafeFiles.attributes(root(ws))!.st_mode & 0o777,0o700)
        for name in try snapshot(ws).keys { XCTAssertEqual(try SafeFiles.attributes(root(ws).appendingPathComponent(name))!.st_mode & 0o777,0o600) }
    }
    func testFinishedReopenAndNewRunIDCannotResetCounters() throws {
        let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws); try execute(disk)
        let before = try snapshot(ws)
        try blocked(ws)
        let j = try SyntheticABJournal(disk:disk), t = transport()
        XCTAssertThrowsError(try runner("synthetic-ab-ee260914-0000-4000-8000-000000009201").run(transport:t,journal:j,environment:.init()))
        XCTAssertTrue(t.calls.isEmpty); XCTAssertEqual(try snapshot(ws),before)
    }
    func testResponseLossRetainsAttemptAndChargeAndStops() throws {
        let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws), e = SyntheticABExpected.fixture()
        var responses = e.responses()+e.responses(); responses[0].lost = true
        let t = SyntheticABTransport(responses)
        XCTAssertThrowsError(try execute(disk,t))
        let s = try disk.read(); XCTAssertEqual(s.status,"stopped"); XCTAssertEqual(s.httpUsed,1); XCTAssertEqual(s.authUsed,1)
        XCTAssertNotNil(s.events[0].startedMonoMS); XCTAssertNil(s.events[0].receivedMonoMS); XCTAssertEqual(t.calls.count,1)
        try blocked(ws)
    }
    func testRejectedHTTPKeepsSafeMetadataWithoutBody() throws {
        let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws), e = SyntheticABExpected.fixture()
        var responses = e.responses(); responses[0].status = 401; responses[0].raw = Data("synthetic-sensitive-error".utf8)
        XCTAssertThrowsError(try execute(disk,SyntheticABTransport(responses)))
        let state = try disk.read(); XCTAssertEqual(state.events[0].status,401); XCTAssertNil(state.events[0].raw)
        XCTAssertFalse(try snapshot(ws).values.contains { String(decoding:$0,as:UTF8.self).contains("synthetic-sensitive-error") })
        try blocked(ws)
    }
    func testCancelledAfterReservationDoesNotSendOrRefund() throws {
        let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws), t = transport()
        var delays = SyntheticABDelays(); delays.reservationEffect = .cancel
        XCTAssertThrowsError(try execute(disk,t,nil,delays))
        let state = try disk.read(); XCTAssertEqual(state.httpUsed,1); XCTAssertEqual(state.authUsed,1); XCTAssertEqual(state.status,"stopped")
        XCTAssertNil(state.events[0].startedMonoMS); XCTAssertTrue(t.calls.isEmpty); try blocked(ws)
    }
    func testAllReservationAndStartPublicationsPrecedeTransport() throws {
        let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws), t = transport()
        var seen = 0
        disk.checkpoint = { p in
            if p.hasPrefix("committed:reserve:") || p.hasPrefix("committed:start:") {
                let n = Int(p.split(separator:":").last!)!
                XCTAssertEqual(t.calls.count,n-1)
                XCTAssertEqual(try disk.read().httpUsed,n)
                seen += 1
            }
        }
        try execute(disk,t); XCTAssertEqual(seen,28)
    }
    func testClaimReservationAndStartNoOpWritesBlockBeforeSend() throws {
        for op in ["claim","reserve:1","start:1"] {
            let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws), j = try SyntheticABJournal(disk:disk), t = transport()
            j.skipOperation = op; XCTAssertThrowsError(try execute(disk,t,j))
            XCTAssertTrue(j.poisoned); XCTAssertTrue(t.calls.isEmpty); try blocked(ws)
        }
    }
    func testFailedBeforeAndAfterChargeCannotRefundOrContinue() throws {
        for after in [false,true] {
            let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws), j = try SyntheticABJournal(disk:disk), t = transport()
            if after { j.failAfter = "reserve:1" } else { j.failBefore = "reserve:1" }
            XCTAssertThrowsError(try execute(disk,t,j)); XCTAssertTrue(t.calls.isEmpty)
            let s = try disk.read(); XCTAssertEqual(s.status,"running"); XCTAssertEqual(s.httpUsed,after ? 1 : 0)
            XCTAssertThrowsError(try j.write(s,operation:"stop")); try blocked(ws)
        }
    }
    func testFaultsBeforePendingAfterPublicationAndAfterCommitPreserveEvidence() throws {
        for point in ["created-root","locked-new","pending:initialize:owner.json","published:initialize:owner.json","pending:initialize:record-000.json","published:initialize:record-000.json","pending:initialize:head.json","committed:initialize","before:reserve:1:record-002.json","pending:reserve:1:record-002.json","published:reserve:1:record-002.json","pending:reserve:1:head.json","published:reserve:1:head.json","committed:reserve:1"] {
            let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws), t = transport(); stop(disk,at:point)
            XCTAssertThrowsError(try execute(disk,t),point); XCTAssertTrue(t.calls.isEmpty,point); try blocked(ws)
        }
    }
    func testMetadataResponseProbeAndFinishFailuresCannotContinue() throws {
        for point in ["pending:metadata:1:head.json","committed:metadata:1","pending:response:1:head.json","committed:response:1","committed:local_start","pending:finish:head.json","committed:finish"] {
            let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws), t = transport(); stop(disk,at:point)
            XCTAssertThrowsError(try execute(disk,t),point)
            XCTAssertEqual(t.calls.count,point.contains("local_start") || point.contains("finish") ? 14 : 1)
            try blocked(ws)
        }
    }
    func testReadOnlyInspectDoesNotRewriteFiles() throws {
        let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws); try execute(disk)
        let before = try snapshot(ws)
        let dates = try before.keys.map { try fm.attributesOfItem(atPath:root(ws).appendingPathComponent($0).path)[.modificationDate] as! Date }
        _ = try SyntheticABDiskJournal(workspace:ws).read()
        XCTAssertEqual(try snapshot(ws),before)
        for (name,date) in zip(before.keys,dates) { XCTAssertEqual(try fm.attributesOfItem(atPath:root(ws).appendingPathComponent(name).path)[.modificationDate] as? Date,date) }
    }
    func testMissingHeadOwnerLockAndAnyInteriorRecordAreNotReinitialized() throws {
        let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws); try execute(disk)
        let original = try snapshot(ws)
        for name in ["owner.json","head.json","lock","record-000.json","record-002.json","record-058.json"] {
            let url = root(ws).appendingPathComponent(name); try fm.removeItem(at:url); try blocked(ws)
            try original[name]!.write(to:url); try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        }
    }
    func testCorruptHeadOwnerAndRecordPreserveAndBlock() throws {
        let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws); try execute(disk)
        let original = try snapshot(ws)
        for name in ["owner.json","head.json","record-000.json","record-002.json","record-059.json"] {
            let url = root(ws).appendingPathComponent(name); try Data("{}\n".utf8).write(to:url); try blocked(ws)
            try original[name]!.write(to:url)
        }
    }
    func testPendingOrphanForeignFileAndDirectoryBlock() throws {
        let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws); try execute(disk)
        for name in ["head.json.pending","record-060.json","draft.txt","foreign"] {
            let url = root(ws).appendingPathComponent(name)
            if name == "foreign" { try fm.createDirectory(at:url,withIntermediateDirectories:false) } else { try Data("preserve".utf8).write(to:url) }
            try blocked(ws); XCTAssertTrue(fm.fileExists(atPath:url.path)); try fm.removeItem(at:url)
        }
    }
    func testEmptyOrPopulatedExistingRootNeverAdopted() throws {
        for populated in [false,true] {
            let ws = try workspace(); try fm.createDirectory(at:root(ws),withIntermediateDirectories:false)
            if populated { try Data("unsent".utf8).write(to:root(ws).appendingPathComponent("original.txt")) }
            try blocked(ws)
        }
    }
    func testCopiedStoreRejectsDifferentWorkspaceBinding() throws {
        let a = try workspace(), b = try workspace(); try execute(SyntheticABDiskJournal(workspace:a))
        let original = try snapshot(a); try fm.copyItem(at:root(a),to:root(b)); try blocked(b); XCTAssertEqual(try snapshot(a),original)
    }
    func testNonTemporaryIdentityAndForeignSiblingNeverCreateJournal() throws {
        let ws = try workspace()
        XCTAssertThrowsError(try SyntheticABDiskJournal(workspace:ws.appendingPathComponent("store")))
        XCTAssertThrowsError(try SyntheticABDiskJournal(workspace:URL(fileURLWithPath:"/tmp/SyntheticABJournal-"+UUID().uuidString.lowercased())))
        let sibling = ws.appendingPathComponent("old-original.txt"); try Data("18/19 originals are not fixtures".utf8).write(to:sibling)
        XCTAssertThrowsError(try SyntheticABDiskJournal(workspace:ws)); XCTAssertFalse(fm.fileExists(atPath:root(ws).path))
        XCTAssertEqual(try Data(contentsOf:sibling),Data("18/19 originals are not fixtures".utf8))
    }
    func testSymlinkRootAndHardlinkRecordAreRejectedWithoutTouchingTarget() throws {
        let a = try workspace(), b = try workspace(); try execute(SyntheticABDiskJournal(workspace:a)); let original = try snapshot(a)
        try fm.createSymbolicLink(at:root(b),withDestinationURL:root(a)); XCTAssertThrowsError(try execute(SyntheticABDiskJournal(workspace:b)))
        XCTAssertEqual(try snapshot(a),original); try fm.removeItem(at:root(b))
        let linked = b.appendingPathComponent("hardlink"); try fm.linkItem(at:root(a).appendingPathComponent("record-002.json"),to:linked)
        try blocked(a); XCTAssertEqual(try snapshot(a),original)
    }
    func testWeakPermissionsAreNotAutomaticallyRepaired() throws {
        let ws = try workspace(); try execute(SyntheticABDiskJournal(workspace:ws))
        for name in ["owner.json","lock","record-001.json"] {
            let url = root(ws).appendingPathComponent(name); try fm.setAttributes([.posixPermissions:0o644],ofItemAtPath:url.path)
            try blocked(ws); XCTAssertEqual(try SafeFiles.attributes(url)!.st_mode & 0o777,0o644)
            try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        }
    }
    func testJournalOutsideExecutionLockCannotWrite() throws {
        let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws)
        XCTAssertThrowsError(try disk.write(SyntheticABJournalState(),operation:"claim")); XCTAssertEqual(try snapshot(ws),[:])
    }
    func testAnotherThreadCannotUseHeldDiskLock() throws {
        let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws)
        try disk.acquire(create:true); defer { disk.release() }
        let done = expectation(description:"foreign thread blocked")
        DispatchQueue.global().async {
            do { _ = try disk.read(); XCTFail("foreign thread used held journal lock") }
            catch { XCTAssertEqual(error as? SyntheticABError,.busy) }
            done.fulfill()
        }
        wait(for:[done],timeout:2)
    }
    func testIndependentInstancesCannotShareHeldLock() throws {
        let ws = try workspace(), first = try SyntheticABDiskJournal(workspace:ws), second = try SyntheticABDiskJournal(workspace:ws)
        try first.acquire(create:true); defer { first.release() }
        XCTAssertThrowsError(try second.acquire(create:false)) { XCTAssertEqual($0 as? SyntheticABError,.busy) }
    }
    func testLockReplacementWhileHeldBlocksPublication() throws {
        let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws), t = transport()
        disk.checkpoint = { point in
            if point == "committed:claim" {
                try self.fm.moveItem(at:self.root(ws).appendingPathComponent("lock"),to:self.root(ws).appendingPathComponent("old-lock"))
                try Data().write(to:self.root(ws).appendingPathComponent("lock"))
            }
        }
        XCTAssertThrowsError(try execute(disk,t)); XCTAssertTrue(t.calls.isEmpty); try blocked(ws)
    }
    func testForeignSiblingAppearingWhileHeldBlocksNextRequest() throws {
        let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws), t = transport()
        disk.checkpoint = { if $0 == "committed:response:1" { try Data("unsent".utf8).write(to:ws.appendingPathComponent("original")) } }
        XCTAssertThrowsError(try execute(disk,t)); XCTAssertEqual(t.calls.count,1); try blocked(ws)
    }
    func testTransitionRejectsRefundFieldErasureAndBindingChange() throws {
        let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws); stop(disk,at:"committed:start:1")
        XCTAssertThrowsError(try execute(disk)); let old = try disk.read()
        var new = old; new.status = "stopped"; try SyntheticABDiskJournal.transition(old,new,operation:"stop")
        for mutation in 0..<4 {
            var bad = new
            if mutation == 0 { bad.httpUsed = 0 }; if mutation == 1 { bad.events[0].startedMonoMS = nil }
            if mutation == 2 { bad.binding = String(repeating:"0",count:64) }; if mutation == 3 { bad.events[0].request = nil }
            XCTAssertThrowsError(try SyntheticABDiskJournal.transition(old,bad,operation:"stop"))
        }
    }
    func testTransitionRejectsFalseCompletionAndMalformedOperation() throws {
        let old = SyntheticABJournalState()
        var new = old; new.status = "finished"
        for op in ["finish","reserve:01","reserve:15","response:0","unknown","stop"] { XCTAssertThrowsError(try SyntheticABDiskJournal.transition(old,new,operation:op)) }
    }
    func testOversizedRecordIsRejectedBeforeParsing() throws {
        let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws); stop(disk,at:"committed:claim"); XCTAssertThrowsError(try execute(disk))
        let url = root(ws).appendingPathComponent("record-001.json"), handle = try FileHandle(forWritingTo:url)
        try handle.truncate(atOffset:UInt64(48*1024*1024+1)); try handle.close()
        let t = transport(); XCTAssertThrowsError(try execute(SyntheticABDiskJournal(workspace:ws),t)); XCTAssertTrue(t.calls.isEmpty)
        XCTAssertEqual(try SafeFiles.attributes(url)!.st_size,48*1024*1024+1)
    }
    func testRewoundHeadWithRemainingSuffixIsRejected() throws {
        let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws); try execute(disk)
        let zero = try Data(contentsOf:root(ws).appendingPathComponent("record-000.json"))
        try canonical(SyntheticABDiskJournal.Head(sequence:0,sha256:byteHash(zero))).write(to:root(ws).appendingPathComponent("head.json"))
        try blocked(ws)
    }
    func testReopenedGenesisCannotStartEvenWithoutPriorRequests() throws {
        let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws)
        try disk.acquire(create:true); disk.release()
        try blocked(ws)
        let t = transport(); XCTAssertThrowsError(try execute(disk,t)); XCTAssertTrue(t.calls.isEmpty)
    }
    func testFailedInitializationDoesNotAuthorizeLaterReuse() throws {
        let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws); stop(disk,at:"committed:initialize")
        XCTAssertThrowsError(try execute(disk)); disk.checkpoint = { _ in }; let t = transport()
        XCTAssertThrowsError(try execute(disk,t)); XCTAssertTrue(t.calls.isEmpty); try blocked(ws)
    }
    func testRehashedInvalidFinalStateAndPreviousLinkStillFailClosed() throws {
        let ws = try workspace(); try execute(SyntheticABDiskJournal(workspace:ws))
        let original = try snapshot(ws), url = root(ws).appendingPathComponent("record-059.json")
        let record = try decodeExact(SyntheticABDiskJournal.Record.self,original["record-059.json"]!)
        for mutation in 0..<4 {
            var state = record.state
            if mutation == 0 { state.httpUsed = 13 }
            if mutation == 1 { state.events[0].startedMonoMS = nil }
            if mutation == 2 { state.binding = String(repeating:"a",count:64) }
            let bad = SyntheticABDiskJournal.Record(sequence:record.sequence,previous:mutation == 3 ? String(repeating:"b",count:64) : record.previous,operation:record.operation,state:state)
            let bytes = try canonical(bad); try bytes.write(to:url)
            try canonical(SyntheticABDiskJournal.Head(sequence:59,sha256:byteHash(bytes))).write(to:root(ws).appendingPathComponent("head.json"))
            XCTAssertThrowsError(try SyntheticABDiskJournal(workspace:ws).read())
            try blocked(ws)
        }
    }
    func testReadMissingJournalDoesNotCreateAnything() throws {
        let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws)
        XCTAssertThrowsError(try disk.read()); XCTAssertEqual(try fm.contentsOfDirectory(atPath:ws.path),[])
    }
    func testOutOfRangeHeadAndUnknownCanonicalFieldsCannotBeAccepted() throws {
        let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws)
        try disk.acquire(create:true); disk.release()
        for n in [-1,64,Int.max] {
            try canonical(SyntheticABDiskJournal.Head(sequence:n,sha256:String(repeating:"0",count:64))).write(to:root(ws).appendingPathComponent("head.json"))
            XCTAssertThrowsError(try SyntheticABDiskJournal(workspace:ws).read()); try blocked(ws)
        }
        try Data("{\"sequence\":0,\"sha256\":\"\",\"extra\":true}\n".utf8).write(to:root(ws).appendingPathComponent("head.json"))
        XCTAssertThrowsError(try SyntheticABDiskJournal(workspace:ws).read()); try blocked(ws)
    }
    func testClaimCannotOmitOrRewritePersistedPolicyContext() throws {
        let ws = try workspace(), disk = try SyntheticABDiskJournal(workspace:ws); stop(disk,at:"committed:claim")
        XCTAssertThrowsError(try execute(disk)); let state = try disk.read()
        var omitted = state; omitted.context = nil
        XCTAssertThrowsError(try SyntheticABDiskJournal.transition(SyntheticABJournalState(),omitted,operation:"claim"))
        var erased = state; erased.status = "stopped"; erased.context = nil
        XCTAssertThrowsError(try SyntheticABDiskJournal.transition(state,erased,operation:"stop"))
        let context = try XCTUnwrap(state.context)
        var timing = context.timing; timing.expiresUTCMS += 1
        var wrongPolicy = state
        wrongPolicy.context = .init(configurationBinding:context.configurationBinding,fixtureBinding:context.fixtureBinding,timing:timing,startedUTCMS:context.startedUTCMS,startedMonoMS:context.startedMonoMS,sessionID:context.sessionID,bootID:context.bootID,sessionGeneration:context.sessionGeneration,bootGeneration:context.bootGeneration,sessionExpiresUTCMS:context.sessionExpiresUTCMS,lifecycleGeneration:context.lifecycleGeneration)
        XCTAssertThrowsError(try SyntheticABDiskJournal.transition(SyntheticABJournalState(),wrongPolicy,operation:"claim"))
        var mismatched = state; mismatched.binding = String(repeating:"0",count:64)
        XCTAssertThrowsError(try SyntheticABDiskJournal.transition(SyntheticABJournalState(),mismatched,operation:"claim"))
    }
    func probe() throws -> URL {
        var dir = Bundle(for:Self.self).bundleURL
        for _ in 0..<8 { let file = dir.appendingPathComponent("SyntheticABJournalProbe"); if fm.isExecutableFile(atPath:file.path) { return file }; dir.deleteLastPathComponent() }
        throw ReceiveError.io
    }
    func launch(_ ws: URL,_ point: String,_ mode: String) throws -> (Process,Pipe,Pipe) {
        let p = Process(), output = Pipe(), input = Pipe()
        p.executableURL = try probe(); p.arguments = [ws.path,point,mode]; p.standardOutput = output; p.standardInput = input; p.standardError = Pipe()
        try p.run(); return (p,output,input)
    }
    func finish(_ p: Process) {
        let deadline = Date().addingTimeInterval(15)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval:0.01) }
        if p.isRunning { kill(p.processIdentifier,SIGKILL); XCTFail("host journal probe timeout") }
        p.waitUntilExit()
    }
    func testHostProcessCrashesAtElevenBoundariesAlwaysBlockRestart() throws {
        for point in ["created-root","committed:initialize","committed:claim","pending:reserve:1:record-002.json","published:reserve:1:record-002.json","pending:reserve:1:head.json","committed:reserve:1","committed:start:1","committed:response:1","committed:local_start","committed:finish"] {
            let ws = try workspace(), (p,_,_) = try launch(ws,point,"crash"); finish(p); XCTAssertEqual(p.terminationStatus,73,point)
            let before = try snapshot(ws), (reopened,_,_) = try launch(ws,"","run"); finish(reopened); XCTAssertEqual(reopened.terminationStatus,1,point)
            XCTAssertEqual(try snapshot(ws),before); try blocked(ws)
            print("AB JOURNAL PROCESS BLOCK: \(point), exit=73, restart=1, unchanged=true")
        }
    }
    func testHostProcessLockBlocksContenderAndKillPreservesCharge() throws {
        let ws = try workspace(), (holder,output,input) = try launch(ws,"committed:reserve:1","hold")
        defer { _ = input; if holder.isRunning { kill(holder.processIdentifier,SIGKILL);holder.waitUntilExit() } }
        // Bound the handshake wait; never block the test suite on a missing marker.
        let fd = output.fileHandleForReading.fileDescriptor
        var descriptor = pollfd(fd:fd,events:Int16(POLLIN),revents:0)
        XCTAssertEqual(poll(&descriptor,1,15000),1)
        if descriptor.revents & Int16(POLLIN) == 0 { return XCTFail("host journal lock marker missing") }
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount:7),Data("LOCKED\n".utf8))
        let (contender,_,_) = try launch(ws,"","run"); finish(contender); XCTAssertEqual(contender.terminationStatus,1)
        let before = try snapshot(ws); kill(holder.processIdentifier,SIGKILL); finish(holder)
        XCTAssertEqual(holder.terminationReason,.uncaughtSignal)
        let state = try SyntheticABDiskJournal(workspace:ws).read(); XCTAssertEqual(state.httpUsed,1); XCTAssertEqual(state.authUsed,1); XCTAssertNil(state.events[0].startedMonoMS)
        try blocked(ws); XCTAssertEqual(try snapshot(ws),before)
    }
}
