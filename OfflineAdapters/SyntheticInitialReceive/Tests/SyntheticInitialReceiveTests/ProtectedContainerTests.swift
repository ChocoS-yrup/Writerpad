import Foundation
import Darwin
import XCTest
@testable import SyntheticInitialReceive

final class ProtectedContainerTests: XCTestCase {
    final class Protection {
        var protectedInodes = Set<String>()
        var createdNames: [String] = []
        var firstByteSizes: [Int] = []
        var failCreation: String?
        var rejectVerification: String?
        var onCreate: ((URL) throws -> Void)?
        func key(_ url:URL) throws -> String {
            guard let s = try SafeFiles.attributes(url) else { throw ProtectedBoundaryError.protection }
            return "\(s.st_dev):\(s.st_ino)"
        }
        func create(_ url:URL) throws {
            if url.lastPathComponent == failCreation { throw ProtectedBoundaryError.protection }
            createdNames.append(url.lastPathComponent)
            if let s = try SafeFiles.attributes(url), s.st_mode & S_IFMT == S_IFREG { firstByteSizes.append(Int(s.st_size)) }
            protectedInodes.insert(try key(url)); try onCreate?(url)
        }
        func verify(_ url:URL) throws {
            guard url.lastPathComponent != rejectVerification, protectedInodes.contains(try key(url)) else { throw ProtectedBoundaryError.protection }
        }
        func access(_ lease:BoundaryLease) -> PhysicalStorageAccess {
            PhysicalStorageAccess(check:lease.check,created:{ url in try lease.check();try self.create(url);try self.verify(url);try lease.check() },
                                  verify:{ url in try lease.check();try self.verify(url) })
        }
    }
    let fm = FileManager.default
    func home() throws -> URL {
        let url = URL(fileURLWithPath:try SafeFiles.temporaryPath()).appendingPathComponent("IOSBoundaryFakeHome-"+UUID().uuidString)
        try fm.createDirectory(at:url,withIntermediateDirectories:false)
        addTeardownBlock { try? self.fm.removeItem(at:url) }
        return url
    }
    func active() -> BoundaryLifecycle {
        let life = BoundaryLifecycle();life.update(active:true,protectedDataAvailable:true);return life
    }
    func container(_ home:URL,_ life:BoundaryLifecycle,_ protection:Protection) throws -> ProtectedBoundaryContainer {
        try ProtectedBoundaryContainer(home:home,declaredBundle:ProtectedBoundaryContainer.bundleID,access:protection.access(life.begin()))
    }
    func tree(_ root:URL) throws -> [String:Data] {
        var files: [String:Data] = [:]
        func visit(_ directory:URL,_ prefix:String) throws {
            for name in try fm.contentsOfDirectory(atPath:directory.path) {
                let url = directory.appendingPathComponent(name)
                guard let s = try SafeFiles.attributes(url) else { throw ReceiveError.io }
                if s.st_mode & S_IFMT == S_IFDIR { try visit(url,prefix+name+"/") }
                else { files[prefix+name] = try SafeFiles.read(url) }
            }
        }
        try visit(root,"");return files
    }

    private var legacyPath:String { "/private/var/mobile/Containers/Data/Application/2665AA0B-8F8A-43DD-BE03-57A45243C65E/" + ProtectedBoundaryContainer.relativeWorkspace }
    private func legacy(_ c:ProtectedBoundaryContainer,_ p:Protection,path:String?=nil,version:Int=1,bundle:String=ProtectedBoundaryContainer.bundleID,kind:String="dedicated-synthetic-container-v1") throws {
        let file=c.workspace.appendingPathComponent("container.json")
        try canonical(ProtectedBoundaryContainer.Seal(version:version,bundleID:bundle,workspace:path ?? legacyPath,kind:kind)).write(to:file)
        try p.create(file)
    }
    func testNewSealIsRelativeV2AndReopenNeverWrites() throws {
        let h=try home(),p=Protection(),life=active(),c=try container(h,life,p)
        try c.prepare()
        let data=try SafeFiles.read(c.workspace.appendingPathComponent("container.json"))
        let seal=try decodeExact(ProtectedBoundaryContainer.Seal.self,data)
        XCTAssertEqual(seal.version,2);XCTAssertEqual(seal.workspace,ProtectedBoundaryContainer.relativeWorkspace)
        let calls=p.createdNames
        try c.prepare();try c.validate(c.workspace)
        XCTAssertEqual(p.createdNames,calls)
    }
    func testLegacyMigrationPreservesPhysicalBytesAndIsIdempotent() throws {
        let h=try home(),p=Protection(),life=active(),c=try container(h,life,p)
        try c.prepare();try c.session(input:BoundaryAppFixture.make()).apply();try legacy(c,p)
        let before=try tree(c.workspace)
        XCTAssertThrowsError(try c.validate(c.workspace))
        XCTAssertEqual(try tree(c.workspace),before) // validate never migrates
        try c.prepare();try c.validate(c.workspace)
        let after=try tree(c.workspace)
        XCTAssertEqual(before.filter{$0.key != "container.json"},after.filter{$0.key != "container.json"})
        XCTAssertNotEqual(before["container.json"],after["container.json"])
        let calls=p.createdNames
        try container(h,life,p).prepare()
        XCTAssertEqual(try tree(c.workspace),after);XCTAssertEqual(calls,p.createdNames)
    }
    func testLegacyMalformedPathsAndIdentityFailWithoutWrites() throws {
        let h=try home(),p=Protection(),life=active(),c=try container(h,life,p)
        try c.prepare()
        for path in [legacyPath+"/",legacyPath+"evil",legacyPath.replacingOccurrences(of:"2665AA0B-8F8A-43DD-BE03-57A45243C65E",with:"not-uuid"),"/tmp/"+ProtectedBoundaryContainer.relativeWorkspace,legacyPath.replacingOccurrences(of:"/Library/",with:"/../Library/")] {
            try legacy(c,p,path:path);let before=try tree(c.workspace)
            XCTAssertThrowsError(try c.prepare());XCTAssertEqual(try tree(c.workspace),before)
        }
        for (version,bundle,kind) in [(3,ProtectedBoundaryContainer.bundleID,"dedicated-synthetic-container-v1"),(1,"foreign","dedicated-synthetic-container-v1"),(1,ProtectedBoundaryContainer.bundleID,"foreign")] {
            try legacy(c,p,version:version,bundle:bundle,kind:kind);let before=try tree(c.workspace)
            XCTAssertThrowsError(try c.prepare());XCTAssertEqual(try tree(c.workspace),before)
        }
    }
    func testLegacyUnexpectedContentsAndChildSymlinkBlock() throws {
        let h=try home(),p=Protection(),life=active(),c=try container(h,life,p)
        try c.prepare();try legacy(c,p)
        let extra=c.workspace.appendingPathComponent("foreign")
        try Data([1]).write(to:extra);let before=try tree(c.workspace)
        XCTAssertThrowsError(try c.prepare()){XCTAssertEqual($0 as? ProtectedBoundaryError,.incompleteContainer)}
        XCTAssertEqual(try tree(c.workspace),before);try fm.removeItem(at:extra)
        let outside=h.appendingPathComponent("outside");try Data([2]).write(to:outside)
        try fm.createSymbolicLink(at:c.workspace.appendingPathComponent("physical-boundary"),withDestinationURL:outside)
        XCTAssertThrowsError(try c.prepare());XCTAssertEqual(try Data(contentsOf:outside),Data([2]))
    }
    func testMigrationProtectionFailurePreservesOriginalAndPendingBlocksRetry() throws {
        let h=try home(),p=Protection(),life=active(),c=try container(h,life,p)
        try c.prepare();try c.session(input:BoundaryAppFixture.make()).apply();try legacy(c,p)
        let before=try tree(c.workspace)
        p.rejectVerification="physical-boundary"
        XCTAssertThrowsError(try c.prepare());XCTAssertEqual(try tree(c.workspace),before)
        p.rejectVerification=nil;p.failCreation="container.json.pending"
        XCTAssertThrowsError(try c.prepare())
        let after=try tree(c.workspace)
        for (name,bytes) in before {XCTAssertEqual(after[name],bytes)}
        p.failCreation=nil
        XCTAssertThrowsError(try c.prepare());XCTAssertEqual(try tree(c.workspace),after)
    }
    func testMigrationIOErrorAtSyncedPendingCheckpointPreservesOriginal() throws {
        let h=try home(),p=Protection(),life=active(),c=try container(h,life,p)
        try c.prepare();try c.session(input:BoundaryAppFixture.make()).apply();try legacy(c,p)
        let before=try tree(c.workspace),lease=try life.begin()
        let pending=c.workspace.appendingPathComponent("container.json.pending")
        var access=p.access(lease)
        access.check={
            try lease.check()
            if let info=try SafeFiles.attributes(pending),info.st_size>0 {throw ReceiveError.io}
        }
        let interrupted=try ProtectedBoundaryContainer(home:h,declaredBundle:ProtectedBoundaryContainer.bundleID,access:access)
        XCTAssertThrowsError(try interrupted.prepare())
        let after=try tree(c.workspace)
        XCTAssertGreaterThan(after["container.json.pending"]?.count ?? 0,0)
        for (name,bytes) in before {XCTAssertEqual(after[name],bytes)}
        XCTAssertThrowsError(try c.prepare())
    }

    func testMigrationRevocationBeforeRenamePreservesOriginal() throws {
        let h=try home(),p=Protection(),life=active(),c=try container(h,life,p)
        try c.prepare();try legacy(c,p);let before=try tree(c.workspace)
        p.onCreate={url in if url.lastPathComponent=="container.json.pending" {life.update(active:false,protectedDataAvailable:true)}}
        XCTAssertThrowsError(try c.prepare())
        let after=try tree(c.workspace)
        for (name,bytes) in before {XCTAssertEqual(after[name],bytes)}
    }

    // Build a byte-consistent legacy fixture; production never rewrites these records.
    private func rewriteLegacyRecords(_ c:ProtectedBoundaryContainer,_ p:Protection,
                                      change:(Int,inout [String:Any])->Void = {_,_ in}) throws {
        let root=c.workspace.appendingPathComponent("physical-boundary")
        var previous=""
        for n in 1...9 {
            let file=root.appendingPathComponent(String(format:"record-%02d.json",n))
            var record=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
            var binding=record["binding"] as! [String:Any]
            binding["version"]=1;binding["root"]=legacyPath+"/physical-boundary"
            change(n,&binding);record["binding"]=binding;record["previousHash"]=previous
            let bytes=try canonical(JSONDecoder().decode(PhysicalBoundaryStorage.Record.self,from:JSONSerialization.data(withJSONObject:record)))
            try bytes.write(to:file);try p.create(file);previous=byteHash(bytes)
        }
        let head=root.appendingPathComponent("head.json")
        try canonical(PhysicalBoundaryStorage.Head(version:1,sequence:9,recordHash:previous)).write(to:head)
        try p.create(head)
    }
    func testCompleteLegacyPhysicalChainReopensWithoutRewritingAnyByte() throws {
        let h=try home(),p=Protection(),life=active(),c=try container(h,life,p)
        try c.prepare();try c.session(input:BoundaryAppFixture.make()).apply()
        try rewriteLegacyRecords(c,p);try legacy(c,p)
        let before=try tree(c.workspace)
        try c.prepare()
        let session=try c.session(input:BoundaryAppFixture.make())
        XCTAssertTrue(try session.apply().synthetic_boundary_ready)
        XCTAssertEqual(try session.snapshot().count,5)
        let after=try tree(c.workspace)
        XCTAssertEqual(before.filter{$0.key != "container.json"},after.filter{$0.key != "container.json"})
        let calls=p.createdNames
        try container(h,life,p).session(input:BoundaryAppFixture.make()).apply()
        XCTAssertEqual(try tree(c.workspace),after);XCTAssertEqual(calls,p.createdNames)
    }
    func testLegacyPhysicalBindingRejectsForeignFieldsMixedRootsAndMalformedPath() throws {
        for mutation in 0...3 {
            let h=try home(),p=Protection(),life=active(),c=try container(h,life,p)
            try c.prepare();try c.session(input:BoundaryAppFixture.make()).apply()
            try rewriteLegacyRecords(c,p){n,binding in
                switch mutation {
                case 0:binding["inputDigest"]=String(repeating:"0",count:64)
                case 1:if n==5 {binding["root"]=self.legacyPath.replacingOccurrences(of:"2665AA0B",with:"3665AA0B")+"/physical-boundary"}
                case 2:binding["root"]="/tmp/"+ProtectedBoundaryContainer.relativeWorkspace+"/physical-boundary"
                default:binding["declaredBundle"]="foreign"
                }
            }
            let before=try tree(c.workspace)
            XCTAssertThrowsError(try c.session(input:BoundaryAppFixture.make()).apply())
            XCTAssertEqual(try tree(c.workspace),before)
        }
    }
    func testLegacyPhysicalChainHashAndPayloadTamperStillRejected() throws {
        for name in ["record-04.json","part-bodies.bin"] {
            let h=try home(),p=Protection(),life=active(),c=try container(h,life,p)
            try c.prepare();try c.session(input:BoundaryAppFixture.make()).apply();try rewriteLegacyRecords(c,p)
            let file=c.workspace.appendingPathComponent("physical-boundary/"+name)
            var bytes=try Data(contentsOf:file);bytes.append(32);try bytes.write(to:file);try p.create(file)
            let before=try tree(c.workspace)
            XCTAssertThrowsError(try c.session(input:BoundaryAppFixture.make()).apply())
            XCTAssertEqual(try tree(c.workspace),before)
        }
    }
    func testIncompleteLegacyPhysicalChainIsNotResumed() throws {
        let h=try home(),p=Protection(),life=active(),c=try container(h,life,p)
        try c.prepare();try c.session(input:BoundaryAppFixture.make()).apply();try rewriteLegacyRecords(c,p)
        let root=c.workspace.appendingPathComponent("physical-boundary"),head=root.appendingPathComponent("head.json")
        let hash=byteHash(try Data(contentsOf:root.appendingPathComponent("record-08.json")))
        try canonical(PhysicalBoundaryStorage.Head(version:1,sequence:8,recordHash:hash)).write(to:head);try p.create(head)
        try fm.removeItem(at:root.appendingPathComponent("record-09.json"))
        let before=try tree(c.workspace)
        XCTAssertThrowsError(try c.session(input:BoundaryAppFixture.make()).apply());XCTAssertEqual(try tree(c.workspace),before)
    }
    func testNewPhysicalBindingIsRelativeAndSurvivesHomeMove() throws {
        let h=try home(),p=Protection(),life=active(),c=try container(h,life,p)
        try c.prepare();let session=try c.session(input:BoundaryAppFixture.make())
        XCTAssertEqual(session.binding.version,2)
        XCTAssertEqual(session.binding.root,ProtectedBoundaryContainer.relativeWorkspace+"/physical-boundary")
        try session.apply();let before=try tree(c.workspace)
        let moved=try home(),destination=moved.appendingPathComponent("Library")
        try fm.moveItem(at:h.appendingPathComponent("Library"),to:destination)
        let reopened=try container(moved,life,p);try reopened.prepare()
        XCTAssertTrue(try reopened.session(input:BoundaryAppFixture.make()).apply().synthetic_boundary_ready)
        XCTAssertEqual(try tree(reopened.workspace),before)
    }

    func testUnknownInactiveAndLockedLifecycleCannotIssueLease() throws {
        let life = BoundaryLifecycle()
        XCTAssertThrowsError(try life.begin())
        for flags in [(false,true),(true,false),(false,false)] {
            life.update(active:flags.0,protectedDataAvailable:flags.1)
            XCTAssertThrowsError(try life.begin())
        }
    }
    func testOnlyCompleteProtectionAttributeRepresentationsAreAccepted() throws {
        try CompleteFileProtection.require(FileProtectionType.complete)
        try CompleteFileProtection.require(FileProtectionType.complete.rawValue)
        for value: Any? in [nil,true,0,"",FileProtectionType.none,FileProtectionType.completeUnlessOpen,FileProtectionType.completeUntilFirstUserAuthentication] {
            XCTAssertThrowsError(try CompleteFileProtection.require(value))
        }
    }
    func testRestoringForegroundOrUnlockNeverRevivesOldLease() throws {
        let life = active(), old = try life.begin()
        for flags in [(false,true),(true,false),(false,false),(true,true)] {
            life.update(active:flags.0,protectedDataAvailable:flags.1)
            XCTAssertThrowsError(try old.check())
        }
        XCTAssertNoThrow(try life.begin().check())
    }
    func testRevocationBeforePrepareMakesNoDirectories() throws {
        let h = try home(), life = active(), p = Protection(), c = try container(h,life,p)
        life.update(active:false,protectedDataAvailable:true)
        XCTAssertThrowsError(try c.prepare());XCTAssertEqual(try tree(h),[:]);XCTAssertEqual(p.createdNames,[])
    }
    func testContainerCreatesOnlyDedicatedNamespaceAndPreservesNeighbors() throws {
        let h = try home(), life = active(), p = Protection()
        let support = h.appendingPathComponent("Library/Application Support")
        try fm.createDirectory(at:support,withIntermediateDirectories:true)
        let original = support.appendingPathComponent("original.bin"), bytes = Data(repeating:71,count:19)
        try bytes.write(to:original)
        let c = try container(h,life,p);try c.prepare()
        XCTAssertEqual(try Data(contentsOf:original),bytes)
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath:c.workspace.path)),["container.json"])
        XCTAssertFalse(p.createdNames.contains("Application Support"))
    }
    func testWrongBundleAndWorkspaceRejectedWithoutAdoption() throws {
        let h = try home(), life = active(), p = Protection()
        XCTAssertThrowsError(try ProtectedBoundaryContainer(home:h,declaredBundle:LocalBoundaryContext.expectedBundle,access:p.access(life.begin())))
        XCTAssertEqual(try tree(h),[:])
        let c = try container(h,life,p);try c.prepare()
        XCTAssertThrowsError(try c.validate(h))
    }
    func testEmptyUnownedOrForeignContainerBlocksWithoutRepair() throws {
        let h = try home(), life = active(), p = Protection(), c = try container(h,life,p)
        try fm.createDirectory(at:c.workspace,withIntermediateDirectories:true)
        try p.create(c.workspace)
        let before = try tree(h)
        XCTAssertThrowsError(try c.prepare());XCTAssertEqual(try tree(h),before)
    }
    func testContainerSealAndPendingBootstrapPreservedOnFailure() throws {
        let h = try home(), life = active(), p = Protection(), c = try container(h,life,p)
        p.failCreation = "container.json.pending"
        XCTAssertThrowsError(try c.prepare())
        let before = try tree(h)
        XCTAssertTrue(before.keys.contains { $0.hasSuffix("container.json.pending") })
        p.failCreation = nil
        XCTAssertThrowsError(try c.prepare());XCTAssertEqual(try tree(h),before)
    }
    func testExistingSealTamperNeverResetsIdentity() throws {
        let h = try home(), life = active(), p = Protection(), c = try container(h,life,p)
        try c.prepare();try Data("{}\n".utf8).write(to:c.workspace.appendingPathComponent("container.json"))
        let before = try tree(h)
        XCTAssertThrowsError(try c.prepare());XCTAssertEqual(try tree(h),before)
    }
    func testAllFivePhysicalPartsThroughContainerKeepRealAuthorityClosed() throws {
        let h = try home(), life = active(), p = Protection(), c = try container(h,life,p)
        try c.prepare();let session = try c.session(input:BoundaryAppFixture.make())
        let receipt = try session.apply(), snapshot = try session.snapshot()
        XCTAssertEqual(snapshot.count,5);XCTAssertTrue(receipt.synthetic_boundary_ready)
        XCTAssertFalse(receipt.baseline_applied || receipt.execution_allowed || receipt.app_binding_created || receipt.editing_allowed || receipt.sending_allowed || receipt.automatic_receive_allowed)
        XCTAssertEqual(try tree(c.workspace).count,17) // 15 store files, lock, container seal
    }
    func testProtectionSetBeforeFirstPayloadAndMetadataBytes() throws {
        let h = try home(), life = active(), p = Protection(), c = try container(h,life,p)
        try c.prepare();try c.session(input:BoundaryAppFixture.make()).apply()
        XCTAssertGreaterThan(p.firstByteSizes.count,15)
        XCTAssertTrue(p.firstByteSizes.allSatisfy { $0 == 0 })
        for part in LocalStoragePart.allCases { XCTAssertTrue(p.createdNames.contains("part-\(part.rawValue).bin.pending")) }
    }
    func testProtectionFailureLeavesEmptyPendingAndNoBodyWrite() throws {
        let h = try home(), life = active(), p = Protection(), c = try container(h,life,p)
        try c.prepare();p.failCreation = "part-bodies.bin.pending"
        let session = try c.session(input:BoundaryAppFixture.make())
        XCTAssertThrowsError(try session.apply())
        let before = try tree(h)
        let pending = try XCTUnwrap(before.first { $0.key.hasSuffix("part-bodies.bin.pending") }?.value)
        XCTAssertEqual(pending.count,0)
        p.failCreation = nil
        XCTAssertThrowsError(try session.apply());XCTAssertEqual(try tree(h),before)
    }
    func testBackgroundDuringCreationLeavesPartialEvidenceAndBlocksOldLease() throws {
        let h = try home(), life = active(), p = Protection(), c = try container(h,life,p)
        try c.prepare()
        p.onCreate = { url in if url.lastPathComponent == "part-bodies.bin.pending" { life.update(active:false,protectedDataAvailable:true) } }
        let session = try c.session(input:BoundaryAppFixture.make())
        XCTAssertThrowsError(try session.apply());let before = try tree(h)
        life.update(active:true,protectedDataAvailable:true);p.onCreate = nil
        XCTAssertThrowsError(try session.apply())
        let reopened = try container(h,life,p);try reopened.prepare()
        XCTAssertThrowsError(try reopened.session(input:BoundaryAppFixture.make()).apply())
        XCTAssertEqual(try tree(h),before)
    }
    func testCompletedSnapshotRevokedOnLockAndExplicitFreshLeaseCanReopen() throws {
        let h = try home(), life = active(), p = Protection(), c = try container(h,life,p)
        try c.prepare();let session = try c.session(input:BoundaryAppFixture.make());try session.apply()
        let before = try tree(h)
        life.update(active:true,protectedDataAvailable:false)
        XCTAssertThrowsError(try session.snapshot())
        life.update(active:true,protectedDataAvailable:true)
        XCTAssertThrowsError(try session.snapshot())
        let reopened = try container(h,life,p);try reopened.prepare()
        XCTAssertEqual(try reopened.session(input:BoundaryAppFixture.make()).snapshot().count,5)
        XCTAssertEqual(try tree(h),before)
    }
    func testWeakerExistingFileProtectionIsNotSilentlyUpgraded() throws {
        let h = try home(), life = active(), p = Protection(), c = try container(h,life,p)
        try c.prepare();let session = try c.session(input:BoundaryAppFixture.make());try session.apply()
        let before = try tree(h), calls = p.createdNames
        p.rejectVerification = "part-bodies.bin"
        XCTAssertThrowsError(try session.snapshot());XCTAssertThrowsError(try session.apply())
        XCTAssertEqual(try tree(h),before);XCTAssertEqual(p.createdNames,calls)
    }
    func testWeakerDirectoryProtectionBlocksBeforeLockCreation() throws {
        let h = try home(), life = active(), p = Protection(), c = try container(h,life,p)
        try c.prepare();p.rejectVerification = c.workspace.lastPathComponent
        let before = try tree(h)
        XCTAssertThrowsError(try c.session(input:BoundaryAppFixture.make()));XCTAssertEqual(try tree(h),before)
    }
    func testRepeatPreparationAndApplyDoNotRewriteProtectedContainer() throws {
        let h = try home(), life = active(), p = Protection(), c = try container(h,life,p)
        try c.prepare();try c.session(input:BoundaryAppFixture.make()).apply()
        let before = try tree(h), calls = p.createdNames
        let reopened = try container(h,life,p);try reopened.prepare();try reopened.session(input:BoundaryAppFixture.make()).apply()
        XCTAssertEqual(try tree(h),before);XCTAssertEqual(p.createdNames,calls)
    }
    func testRealCandidateStillBlockedAtProtectedEntry() throws {
        let h = try home(), life = active(), p = Protection(), c = try container(h,life,p)
        try c.prepare();let before = try tree(h)
        let context = LocalBoundaryContext(declaredBundle:ProtectedBoundaryContainer.bundleID,syntheticLocalIdentity:"local-unissued",workspace:c.workspace)
        for input: LocalBoundaryInput in [.realCandidate,.observation,.proposal] {
            XCTAssertThrowsError(try LocalBoundary.prepareProtected(context:context,input:input,container:c,access:p.access(life.begin())))
        }
        XCTAssertEqual(try tree(h),before)
    }
    func testSymlinkedContainerPathPreservesOutsideFile() throws {
        let h = try home(), life = active(), p = Protection(), c = try container(h,life,p)
        let outside = h.appendingPathComponent("protected-original"), bytes = Data(repeating:72,count:18)
        try bytes.write(to:outside)
        try fm.createDirectory(at:c.workspace.deletingLastPathComponent(),withIntermediateDirectories:true)
        try fm.createSymbolicLink(at:c.workspace,withDestinationURL:outside)
        XCTAssertThrowsError(try c.prepare());XCTAssertEqual(try Data(contentsOf:outside),bytes)
    }
}
