import XCTest
import Foundation
import SwiftData
@testable import SyntheticInitialReceive

final class DedicatedEnvironmentTests:XCTestCase {
    enum Injected:Error {case stop}
    private var target:ReviewedReceiveTarget!,draft:ReceiveExecutionCandidate.Draft!,runtime:ReceiveExecutionCandidate.RuntimeSnapshot!
    private var observer:ReceiveAuthCallSiteObserver!,clock:ABRuntimeClock!,responses:[SyntheticABResponse]=[],directories:[URL]=[]
    private var lifecycle:BoundaryLifecycle!
    override func setUpWithError() throws {
        let portable=try Data(contentsOf:Bundle.module.url(forResource:"windows-synthetic-review",withExtension:"json")!)
        let files=try WindowsHandoffReader.files(from:portable)
        let pin=try WindowsJSON.decode(Data(contentsOf:Bundle.module.url(forResource:"windows-synthetic-expectation",withExtension:"json")!))
        target=try .read(portable:portable,expected:.init(handoffSHA256:byteHash(files["handoff.json"]!),bindingJSON:pin.get("binding").encoded()))
        let timing=SyntheticABTiming(requestMS:1000,passMS:10000,interpassMS:1000,preApplyMS:500,localApplyMS:1000,totalMS:60000,notBeforeUTCMS:1000,expiresUTCMS:61000)
        draft = .init(endpoint:"https://synthetic.invalid",account:UUID(uuidString:try target.binding.str("account_id")),project:UUID(uuidString:try target.binding.str("project_id")),handoffSHA256:target.review.handoff_sha256,targetSHA256:target.targetSHA256,runID:UUID(uuidString:"ee260915-0000-4000-8000-000000000381"),localProjectID:UUID(uuidString:"ee260915-0000-4000-8000-000000000382"),bundleID:ProtectedBoundaryContainer.bundleID,bootID:"synthetic-admission-boot",sessionEpoch:1,timing:timing,httpLimit:14,authLimit:2)
        runtime = .init(account:draft.account!,localProjectID:draft.localProjectID!,bundleID:draft.bundleID!,bootID:draft.bootID!,sessionEpoch:1,sessionExpiresUTCMS:61000)
        clock=ABRuntimeClock(utcMS:1000,monoMS:0);observer=ReceiveAuthCallSiteObserver()
        let op=UUID();observer.begin(op);observer.accept(op,account:draft.account!,accessToken:"synthetic.admission.session",expiresAt:Date(timeIntervalSince1970:61))
        lifecycle=BoundaryLifecycle();lifecycle.update(active:true,protectedDataAvailable:true)
        let values=try ["Q1.body","Q2.body","Q3.body","Q4.body","Q14.body","Q15.body","Q16.body"].map{try WindowsJSON.decode(files["source/"+$0]!)}
        responses=try values.enumerated().map{i,v in let count=i>=2 ? try v.array().count:nil;return SyntheticABResponse(raw:v.encoded(lf:true),contentRange:count.map{$0==0 ? "*/0":"0-\($0-1)/\($0)"},delayMS:0)};responses += responses
        ReceiveABStub.reset(responses)
    }
    override func tearDownWithError() throws {ReceiveABStub.reset();for d in directories {try FileManager.default.removeItem(at:d)}}
    private func directory(_ prefix:String="ReceiveInputAdmission-") throws -> URL {
        let d=URL(fileURLWithPath:try SafeFiles.temporaryPath()).appendingPathComponent(prefix+UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at:d,withIntermediateDirectories:false);directories.append(d);return d
    }
    private func descriptor(_ d:URL,mode:ReceiveLocalStoreDescriptor.Mode = .offline,local:String?=nil,bundle:String?=nil)->ReceiveLocalStoreDescriptor {
        .init(mode:mode,localProjectID:local ?? draft.localProjectID!.uuidString.lowercased(),bundleID:bundle ?? draft.bundleID!,workspace:d.path)
    }
    private func execution() throws -> ReceiveReviewedExecution {
        let snapshot=runtime!
        return try .offline(target:target,draft:draft,now:clock.sample(),readRuntime:{snapshot})
    }
    private func received() async throws -> (ReceiveReviewedExecution,ReceiveABCompletion,ReceiveAdmissionPlan) {
        let e=try execution(),home=try directory("AdmissionJournal-")
        let c=try ReceiveABCoordinator(offlineReviewed:e,syntheticHome:home,lease:lifecycle.begin(),protection:.init(),owner:observer.owner,clock:clock,protocolClass:ReceiveABStub.self)
        let completion=try await c.run()
        return (e,completion,try ReceiveAdmissionPlan.offline(execution:e,completion:completion))
    }
    private func authority(_ e:ReceiveReviewedExecution,scopes:Set<ReceiveActivationAuthority.Scope>=[.cachedSession,.httpRead,.productStorage]) throws -> ReceiveActivationAuthority {
        try .offline(execution:e,scopes:scopes,clock:clock,readRuntime:{self.runtime})
    }
    private func paths(_ root:URL)->ReceiveDedicatedPaths {
        .init(root:root,metadata:root.appendingPathComponent("metadata/store.sqlite"),syncDB:root.appendingPathComponent("sync.sqlite"),texts:root.appendingPathComponent("texts"),journal:root.appendingPathComponent("journal"),identity:root.appendingPathComponent("identity.json"))
    }
    private func environment(_ root:URL,_ grant:ReceiveActivationAuthority?,source:ReceiveSessionSource?=nil,identity:@escaping ()throws->Void={}) throws -> ReceiveDedicatedEnvironment {
        try .init(paths:paths(root),local:runtime.localProjectID,bundle:runtime.bundleID,source:source ?? observer.owner.source,authority:grant,clock:clock,lease:lifecycle.begin(),protection:.init(),verifyIdentity:identity)
    }
    private func httpTarget() throws -> ReceiveHTTPTarget {try .init(origin:URL(string:"https://receive-boundary.invalid")!,account:runtime.account,project:draft.project!,publishableKey:"sb_publishable_offline_fixture")}
    private func tree(_ root:URL) throws -> [String:Data] {
        var result:[String:Data]=[:]
        let metadata=paths(root).metadata
        let hasMetadata=FileManager.default.fileExists(atPath:metadata.path)
        let metadataFiles=hasMetadata ? Set([metadata.path,metadata.path+"-wal",metadata.path+"-shm"]) : Set<String>()
        // SwiftData may checkpoint after its context is released. Compare the committed
        // database snapshot, including WAL-resident rows, rather than racing that housekeeping.
        // Every other file (including identity, payloads and sync DB) stays byte-for-byte.
        for case let u as URL in FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey])! {
            if metadataFiles.contains(u.path) {continue}
            if try u.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true {result[u.path]=try Data(contentsOf:u)}
        }
        if hasMetadata {result[metadata.path]=try metadataSnapshot(metadata)}
        return result
    }
    private func metadataSnapshot(_ url:URL) throws -> Data {
        let db=try ReceiveProductSQL(url:url,create:false,check:{})
        // Test observation waits briefly for SwiftData checkpoint locks; product deadlines are unchanged.
        try db.exec("PRAGMA busy_timeout=2000")
        try db.exec("BEGIN")
        defer {try? db.exec("ROLLBACK")}
        var snapshot:[String:[[String?]]]=[:]
        snapshot["schema"]=try db.rows("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY type,name")
        snapshot["version"]=try db.rows("PRAGMA user_version")
        func quoted(_ name:String)->String {"\""+name.replacingOccurrences(of:"\"",with:"\"\"")+"\""}
        for row in try db.rows("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name") {
            let table=row[0]!
            let columns=try db.rows("PRAGMA table_info("+quoted(table)+")").map {"quote("+quoted($0[1]!)+")"}
            let rows=try db.rows("SELECT "+columns.joined(separator:",")+" FROM "+quoted(table))
            // quote() preserves NULL, numeric, text and BLOB values in an unambiguous form.
            snapshot["table:"+table]=rows.sorted { $0.map{$0 ?? ""}.lexicographicallyPrecedes($1.map{$0 ?? ""}) }
        }
        return try canonical(snapshot)
    }
    func testMetadataSnapshotIgnoresCheckpointButDetectsStoredChanges() throws {
        let root=try directory("ReceiveProductStore-"),url=paths(root).metadata
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        let db=try ReceiveProductSQL(url:url,create:true,check:{})
        try db.exec("PRAGMA journal_mode=WAL; CREATE TABLE payload(id INTEGER, body BLOB); INSERT INTO payload VALUES(1, X'0001');")
        let before=try tree(root)
        try db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        XCTAssertEqual(try tree(root),before)
        try db.exec("UPDATE payload SET body=X'0002'")
        XCTAssertNotEqual(try tree(root),before)
    }
    func testConstructionAndMissingAuthorityNeverReadDependencies() throws {
        var reads=0
        let source=ReceiveSessionSource(readCached:{reads+=1;return nil},ownerEpoch:{reads+=1;return 0})
        let root=try directory("ReceiveProductStore-"),env=try environment(root,nil,source:source,identity:{reads+=1})
        XCTAssertEqual(reads,0);XCTAssertThrowsError(try env.connection(target:httpTarget(),offlineProtocol:ReceiveABStub.self))
        XCTAssertEqual(reads,0);XCTAssertTrue(try tree(root).isEmpty);XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testAuthorityScopeAndConnectionReuseAreBlocked() throws {
        let e=try execution(),root=try directory("ReceiveProductStore-")
        let denied=try environment(root,authority(e,scopes:[.productStorage]))
        XCTAssertThrowsError(try denied.connection(target:httpTarget(),offlineProtocol:ReceiveABStub.self))
        let env=try environment(root,authority(e));_ = try env.connection(target:httpTarget(),offlineProtocol:ReceiveABStub.self)
        XCTAssertThrowsError(try env.connection(target:httpTarget(),offlineProtocol:ReceiveABStub.self));XCTAssertEqual(ReceiveABStub.count,0)
    }
    func testRuntimeChangesLatchRevocationAndClockCannotRecover() throws {
        let e=try execution(),g=try authority(e),old=runtime!
        runtime = .init(account:old.account,localProjectID:old.localProjectID,bundleID:old.bundleID,bootID:"replacement",sessionEpoch:old.sessionEpoch,sessionExpiresUTCMS:old.sessionExpiresUTCMS)
        XCTAssertThrowsError(try g.require(.cachedSession));runtime=old;XCTAssertThrowsError(try g.require(.cachedSession))
        let second=try authority(e);try second.require(.httpRead);try clock.setForTest(utcMS:999,monoMS:0)
        XCTAssertThrowsError(try second.require(.httpRead));try clock.setForTest(utcMS:1000,monoMS:0);XCTAssertThrowsError(try second.require(.httpRead))
    }
    func testExpiredAndRevokedAuthorityStopBeforeReservation() async throws {
        let root=try directory("ReceiveProductStore-"),g=try authority(execution()),env=try environment(root,g)
        let c=try env.connection(target:httpTarget(),offlineProtocol:ReceiveABStub.self);var reserved=0;g.revoke()
        do {_ = try await c.send(ordinal:0,timeoutMS:1000,expiresUTCMS:61000,reserveAndStart:{reserved+=1});XCTFail()}catch{}
        XCTAssertEqual(reserved,0);XCTAssertEqual(ReceiveABStub.count,0)
        let g2=try authority(execution());try clock.advance(60000);XCTAssertThrowsError(try g2.require(.httpRead))
    }
    func testAuthorizedSyntheticHTTPUsesExplicitSourceAndDeniesFallback() async throws {
        let root=try directory("ReceiveProductStore-"),env=try environment(root,authority(execution()))
        XCTAssertThrowsError(try env.connection(target:httpTarget()))
        let c=try env.connection(target:httpTarget(),offlineProtocol:ReceiveABStub.self);var reserved=0
        let response=try await c.send(ordinal:0,timeoutMS:1000,expiresUTCMS:61000,reserveAndStart:{reserved+=1})
        XCTAssertEqual(response.bytes,responses[0].raw);XCTAssertEqual(reserved,1);XCTAssertEqual(ReceiveABStub.count,1)
    }
    func testActualSwiftDataSQLiteAndTXTRoundtripThenCorruptionBlocks() async throws {
        let (e,_,p)=try await received(),root=try directory("ReceiveProductStore-"),env=try environment(root,authority(e))
        let store=try env.prepareOffline(plan:p);XCTAssertThrowsError(try store.verifyStored())
        try store.apply();try store.verifyStored()
        XCTAssertThrowsError(try store.requireBaseline());XCTAssertEqual(ReceiveABStub.count,14)
        let sql=try ReceiveProductSQL(url:paths(root).syncDB,create:false,check:{})
        XCTAssertEqual(try sql.rows("PRAGMA user_version"),[["16"]]);XCTAssertEqual(try sql.rows("SELECT count(*) FROM sync_operations"),[["0"]])
        XCTAssertEqual(try sql.rows("SELECT structure_revision FROM sync_documents"),[["1"],["1"]])
        let projection=try ReceiveProductProjection(parts:p.parts,local:runtime.localProjectID,project:draft.project!,account:runtime.account)
        try Data("corrupt".utf8).write(to:paths(root).texts.appendingPathComponent(projection.documents[0].localPath))
        XCTAssertThrowsError(try store.verifyStored());XCTAssertThrowsError(try store.checkPublication());XCTAssertThrowsError(try store.apply())
    }
    func testEachInterruptedStoreStageIsPreservedAndRestartBlocked() async throws {
        let (e,_,p)=try await received()
        for stage in ["texts","metadata","migrations","baselines","readback","complete"] {
            let root=try directory("ReceiveProductStore-"),env=try environment(root,authority(e))
            var reached=false
            let store=try env.prepareOffline(plan:p,checkpoint:{if $0==stage{reached=true;throw Injected.stop}})
            XCTAssertThrowsError(try store.apply());XCTAssertTrue(reached,stage);XCTAssertThrowsError(try store.checkPublication())
            let before=try tree(root),reopened=try environment(root,authority(e))
            XCTAssertThrowsError(try reopened.prepareOffline(plan:p));XCTAssertEqual(try tree(root),before,stage)
        };XCTAssertEqual(ReceiveABStub.count,14)
    }
    func testLocalIODeadlineAndLifecycleLossPreventCompletion() async throws {
        let (e,_,p)=try await received(),root=try directory("ReceiveProductStore-"),env=try environment(root,authority(e))
        let store=try env.prepareOffline(plan:p,checkpoint:{if $0=="metadata"{try self.clock.advance(1000)}})
        XCTAssertThrowsError(try store.apply());XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("complete.json").path));let before=try tree(root)
        XCTAssertThrowsError(try store.verifyStored());XCTAssertEqual(try tree(root),before)
    }
    func testProtectedDataLossAndIdentityMismatchBlockWrites() async throws {
        let (e,_,p)=try await received(),root=try directory("ReceiveProductStore-"),env=try environment(root,authority(e))
        let store=try env.prepareOffline(plan:p,checkpoint:{if $0=="texts"{self.lifecycle.update(active:true,protectedDataAvailable:false)}})
        XCTAssertThrowsError(try store.apply());XCTAssertFalse(FileManager.default.fileExists(atPath:paths(root).metadata.path))
        lifecycle.update(active:true,protectedDataAvailable:true)
        XCTAssertThrowsError(try store.apply())
        let other=try directory("ReceiveProductStore-"),bad=try environment(other,authority(e),identity:{throw ReceiveError.identity})
        XCTAssertThrowsError(try bad.prepareOffline(plan:p));XCTAssertTrue(try tree(other).isEmpty)
    }
    func testExistingFilesAndLinkedPathsArePreserved() async throws {
        let (e,_,p)=try await received(),root=try directory("ReceiveProductStore-")
        try Data("original".utf8).write(to:root.appendingPathComponent("original.txt"));let before=try tree(root)
        XCTAssertThrowsError(try environment(root,authority(e)).prepareOffline(plan:p));XCTAssertEqual(try tree(root),before)
        let other=try directory("ReceiveProductStore-")
        try FileManager.default.createSymbolicLink(at:paths(other).texts,withDestinationURL:root)
        XCTAssertThrowsError(try environment(other,authority(e)).prepareOffline(plan:p));XCTAssertEqual(try tree(root),before)
    }
    func testForeignBindingAndMissingStorageScopeDoNotWrite() async throws {
        let (e,_,p)=try await received(),root=try directory("ReceiveProductStore-")
        XCTAssertThrowsError(try environment(root,authority(e,scopes:[.httpRead,.cachedSession])).prepareOffline(plan:p))
        let env=try ReceiveDedicatedEnvironment(paths:paths(root),local:UUID(uuidString:"ee260915-0000-4000-8000-000000000999")!,bundle:runtime.bundleID,source:observer.owner.source,authority:authority(e),clock:clock,lease:lifecycle.begin(),protection:.init(),verifyIdentity:{})
        XCTAssertThrowsError(try env.prepareOffline(plan:p));XCTAssertTrue(try tree(root).isEmpty)
    }
    func testProjectionExternalParentIsRetainedOnlyInRemoteStorage() async throws {
        let (_,_,p)=try await received();var parts=p.parts
        let parent="ee260915-0000-4000-8000-000000000888"
        for key in [LocalStoragePart.folderBaseline,.metadata] {
            var rows=try WindowsJSON.decode(parts[key]!).array()
            for i in rows.indices {var row=try rows[i].object();if row["folder_id"] != nil {row["parent_folder_id"] = .string(parent);rows[i] = .object(row)}}
            parts[key]=WindowsJSON.array(rows).encoded(lf:true)
        }
        let q=try ReceiveProductProjection(parts:parts,local:runtime.localProjectID,project:draft.project!,account:runtime.account),root=try directory("MappingDisk-")
        XCTAssertEqual(q.root.remoteParent?.uuidString.lowercased(),parent)
        let db=root.appendingPathComponent("sync.sqlite")
        do {let sql=try ReceiveProductSQL(url:db,create:true,check:{});try sql.migrate();try sql.write(q);try sql.verify(q)
            XCTAssertEqual(try sql.rows("SELECT parent_folder_id FROM sync_folders"),[[parent]])}
        let meta=root.appendingPathComponent("metadata.sqlite");try ReceiveProductMetadata.write(q,url:meta,check:{});try ReceiveProductMetadata.verify(q,url:meta,check:{})
        try ReceiveProductMetadata.withContext(url:meta,write:false){c in let rows=try c.fetch(FetchDescriptor<DocumentRecord>());XCTAssertNil(rows.first{$0.id==q.root.id}!.parentID);XCTAssertEqual(rows.count,3)}
    }
    func testProjectionRejectsBodyOrderMetadataAndMemberExpansion() async throws {
        let (_,_,p)=try await received()
        for key in [LocalStoragePart.bodies,.metadata,.documentBaseline,.folderBaseline,.treeOrderBaseline] {
            var parts=p.parts;parts[key]=Data((key == .bodies ? "{}":"[]").utf8)
            XCTAssertThrowsError(try ReceiveProductProjection(parts:parts,local:runtime.localProjectID,project:draft.project!,account:runtime.account))
        }
    }
    @MainActor func testDedicatedAppJobUsesAuthorityABAndRealFormats() async throws {
        let root=try directory("ReceiveProductStore-"),home=try directory("DedicatedJournal-"),e=try execution(),env=try environment(root,authority(e)),app=ReceiveOfflineAppSession(lifecycle:lifecycle)
        await app.run{_ in try ReceiveDedicatedOfflineAppJob(execution:e,environment:env,executionJournalHome:home,protocolClass:ReceiveABStub.self)}
        XCTAssertEqual(app.state,.complete);XCTAssertFalse(app.baselineApplied || app.executionAllowed);XCTAssertEqual(ReceiveABStub.count,14)
        XCTAssertTrue(FileManager.default.fileExists(atPath:paths(root).syncDB.path));XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("complete.json").path))
    }
    func testNewGrantCannotAdoptCompletedNamespaceOrCopiedSeal() async throws {
        let (e,_,p)=try await received(),root=try directory("ReceiveProductStore-"),env=try environment(root,authority(e))
        let store=try env.prepareOffline(plan:p);try store.apply();let before=try tree(root)
        XCTAssertThrowsError(try environment(root,authority(e)).prepareOffline(plan:p));XCTAssertEqual(try tree(root),before)
        let copy=try directory("ReceiveProductStore-")
        try Data(contentsOf:paths(root).identity).write(to:paths(copy).identity)
        XCTAssertThrowsError(try environment(copy,authority(e)).prepareOffline(plan:p))
    }
    func testUnknownFilesAndBaselineCorruptionNeverPublish() async throws {
        let (e,_,p)=try await received()
        for mutation in ["extra","baseline"] {
            let root=try directory("ReceiveProductStore-"),env=try environment(root,authority(e)),store=try env.prepareOffline(plan:p)
            try store.apply()
            if mutation=="extra" {try Data("keep".utf8).write(to:root.appendingPathComponent("unexpected.txt"))}
            else {try Data("broken sqlite".utf8).write(to:paths(root).syncDB)}
            XCTAssertThrowsError(try store.verifyStored());XCTAssertThrowsError(try store.checkPublication())
        }
    }
    func testMigrationResourcesMatchUnchangedProductSources() throws {
        let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for n in 1...16 {XCTAssertEqual(try ReceiveProductSQL.migration(n),try Data(contentsOf:source.appendingPathComponent("Scripts/fixtures/SyncV2StoreSchemaV\(n).sql")))}
    }
    func testSessionInvalidationBetweenDBsPreservesPartialAndNoCompletion() async throws {
        let (e,_,p)=try await received(),root=try directory("ReceiveProductStore-"),env=try environment(root,authority(e))
        let store=try env.prepareOffline(plan:p,checkpoint:{if $0=="metadata" {self.observer.invalidate()}})
        XCTAssertThrowsError(try store.apply());XCTAssertFalse(FileManager.default.fileExists(atPath:paths(root).syncDB.path))
        XCTAssertThrowsError(try store.checkPublication());XCTAssertEqual(ReceiveABStub.count,14)
    }

}
