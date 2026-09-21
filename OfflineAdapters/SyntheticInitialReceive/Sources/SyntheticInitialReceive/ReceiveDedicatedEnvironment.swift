import Foundation
import Darwin

struct ReceiveDedicatedPaths:Equatable {
    let root:URL, metadata:URL, syncDB:URL, texts:URL, journal:URL, identity:URL
    // Only the OS home is canonicalized; descendants retain strict link checks.
    static func live(local:UUID,bundle:String) throws -> Self {
        try make(local:local,bundle:bundle,systemHome:NSHomeDirectory())
    }
    static func make(local:UUID,bundle:String,systemHome:String) throws -> Self {
        try require(bundle==ProtectedBoundaryContainer.bundleID && !local.uuidString.lowercased().hasPrefix("ee2609"),.identity)
        let home=try BoundarySystemHome.resolve(systemHome:systemHome)
        let root=home.appendingPathComponent("Library/Application Support/ReceiveDedicated-v1/"+local.uuidString.lowercased())
        let result=Self(root:root,metadata:root.appendingPathComponent("metadata/store.sqlite"),syncDB:root.appendingPathComponent("sync.sqlite"),texts:root.appendingPathComponent("texts"),journal:root.appendingPathComponent("journal"),identity:root.appendingPathComponent("identity.json"))
        try result.validateComponents()
        return result
    }
    func validateLive(local:String,bundle:String) throws {
        // Called only with a sealed live authority. No path/identity is generated here.
        try require(bundle==ProtectedBoundaryContainer.bundleID && !local.hasPrefix("ee2609") && UUID(uuidString:local) != nil,.identity)
        let home=try BoundarySystemHome.resolve()
        let expected=home.appendingPathComponent("Library/Application Support/ReceiveDedicated-v1/"+local)
        try require(root.path==expected.path,.path);try validateComponents()
    }
    func validate() throws {
        try SafeFiles.checked(root)
        let prefix="ReceiveProductStore-"
        try require([try SafeFiles.temporaryPath(),"/private/tmp"].contains(root.deletingLastPathComponent().path) && root.lastPathComponent.hasPrefix(prefix) && UUID(uuidString:String(root.lastPathComponent.dropFirst(prefix.count))) != nil,.path)
        try validateComponents()
    }
    // Execution only: create missing directories without adopting a nonempty namespace.
    static func prepareEmptyRoot(_ root:URL,access:PhysicalStorageAccess,check:()throws->Void) throws {
        try check();try SafeFiles.checked(root)
        var missing:[URL]=[],cursor=root
        while try SafeFiles.attributes(cursor)==nil {
            missing.append(cursor);cursor=cursor.deletingLastPathComponent()
        }
        for directory in missing.reversed() {
            try check();try SafeFiles.checked(directory)
            guard Darwin.mkdir(directory.path,0o700)==0 else {throw ReceiveError.path}
            try access.created(directory);try access.verify(directory);try check()
        }
        try require(FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty,.existingData)
        try access.created(root);try access.verify(root);try check()
    }
    private func validateComponents() throws {
        try SafeFiles.checked(root)
        let expected=[root.appendingPathComponent("metadata/store.sqlite"),root.appendingPathComponent("sync.sqlite"),root.appendingPathComponent("texts"),root.appendingPathComponent("journal"),root.appendingPathComponent("identity.json")]
        try require([metadata,syncDB,texts,journal,identity].map(\.path)==expected.map(\.path),.path)
        for u in expected{try SafeFiles.checked(u)}
    }
}

// Explicit dependencies only. Construction is inert, and no product factory or Keychain exists here.
final class ReceiveDedicatedEnvironment {
    let paths:ReceiveDedicatedPaths, local:UUID, bundle:String, source:ReceiveSessionSource
    let authority:ReceiveActivationAuthority?, clock:ABRuntimeClock, protection:PhysicalStorageAccess
    let lease:BoundaryLease
    private let verifyIdentity:()throws->Void
    init(paths:ReceiveDedicatedPaths,local:UUID,bundle:String,source:ReceiveSessionSource,authority:ReceiveActivationAuthority?,
         clock:ABRuntimeClock,lease:BoundaryLease,protection:PhysicalStorageAccess,verifyIdentity:@escaping ()throws->Void) {
        self.paths=paths;self.local=local;self.bundle=bundle;self.source=source;self.authority=authority
        self.clock=clock;self.lease=lease;self.protection=protection;self.verifyIdentity=verifyIdentity
    }
    func check(_ scope:ReceiveActivationAuthority.Scope) throws {
        guard let authority else{throw ReceiveConnectionError.closed}
        try connectionNeed(authority.usesClock(clock) && (authority.rehearsal || clock.isSystem),.closed)
        try authority.require(scope);try lease.check();try protection.check();try verifyIdentity();try Task.checkCancellation()
    }
    func validatePaths() throws {
        guard let authority else{throw ReceiveConnectionError.closed}
        try authority.require(.cachedSession)
        if authority.rehearsal {try paths.validate()}else{try paths.validateLive(local:local.uuidString.lowercased(),bundle:bundle)}
        try require(local.uuidString.lowercased()==authority.binding.localProjectID && bundle==authority.binding.bundleID,.identity)
    }
    func connection(target:ReceiveHTTPTarget,offlineProtocol:AnyClass?=nil,additionalCheck:@escaping ()throws->Void={}) throws -> ReceiveHTTPConnection {
        try check(.cachedSession);try check(.httpRead)
        return try .init(authorizedTarget:target,authority:authority,source:source,clock:clock,offlineProtocol:offlineProtocol,leaseCheck:{try self.check(.httpRead);try additionalCheck()})
    }
    func prepareOffline(plan:ReceiveAdmissionPlan,checkpoint:@escaping(String)throws->Void={_ in}) throws -> ReceiveProductStore {
        // Current evidence type remains synthetic: no arbitrary projection or live token can apply it.
        guard let authority,authority.rehearsal else{throw ReceiveConnectionError.closed}
        try authority.require(.productStorage)
        try require(authority.contextDigest==plan.context.digest && local.uuidString.lowercased()==plan.context.localProjectID && bundle==plan.context.bundleID,.identity)
        try paths.validate();try check(.productStorage);try plan.verify()
        return try prepare(proof:ReceiveProductProof.offline(plan),checkpoint:checkpoint)
    }
    func prepare(proof:ReceiveProductProof,checkpoint:@escaping(String)throws->Void={_ in}) throws -> ReceiveProductStore {
        guard let authority else{throw ReceiveConnectionError.closed}
        try authority.require(.productStorage);try validatePaths()
        try require(authority.binding==proof.context && proof.contextTiming==authority.timing && local.uuidString.lowercased()==proof.context.localProjectID && clock === proof.clock,.identity)
        if let bound=proof.grant {try connectionNeed(bound === authority,.closed)}
        try proof.verify();try authority.claim(.productStorage)
        return try ReceiveProductStore(environment:self,plan:proof,checkpoint:checkpoint)
    }
}

// Staged multi-store write. A nonempty namespace is preserved and cannot be auto-resumed.
final class ReceiveProductStore:ReceiveAppReceipt,@unchecked Sendable {
    private let env:ReceiveDedicatedEnvironment,plan:ReceiveProductProof,projection:ReceiveProductProjection
    private let checkpoint:(String)throws->Void
    private let operation=NSLock(),checkLock=NSRecursiveLock()
    private var fd:Int32 = -1, completed=false, attempted=false, localStart:Int?
    private var last:ABRuntimeClock.Sample
    private let completeBytes:Data
    init(environment:ReceiveDedicatedEnvironment,plan:ReceiveProductProof,checkpoint:@escaping(String)throws->Void) throws {
        env=environment;self.plan=plan;self.checkpoint=checkpoint
        last=try env.clock.sample()
        projection=try .init(parts:plan.parts,local:env.local,project:UUID(uuidString:plan.context.project)!,account:UUID(uuidString:plan.context.account)!)
        completeBytes=try canonical(["format":"dedicated-product-store-offline-v1","plan":plan.digest,"context":plan.context.digest,"projection":plan.resultDigest,"local":plan.context.localProjectID])
        try check();try env.validatePaths()
        try ReceiveDedicatedPaths.prepareEmptyRoot(env.paths.root,access:env.protection,check:check)
        fd=open(env.paths.root.appendingPathComponent("operation.lock").path,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
        guard fd>=0,flock(fd,LOCK_EX|LOCK_NB)==0 else{if fd>=0{close(fd)};fd = -1;throw ReceiveError.busy}
        do {
            try protectTree()
            try write(completeBytes,to:env.paths.identity)
            try write(Data("preparing\n".utf8),to:env.paths.root.appendingPathComponent("state"))
            for u in [env.paths.metadata.deletingLastPathComponent(),env.paths.texts,env.paths.journal] {
                try check();try SafeFiles.mkdir(u);try env.protection.created(u);try env.protection.verify(u)
            }
            // Immutable provenance includes exact wire null/date/epoch values absent from SQL columns.
            try write(canonical(plan.context),to:env.paths.journal.appendingPathComponent("context.json"))
            for part in LocalStoragePart.allCases{try write(plan.parts[part]!,to:env.paths.journal.appendingPathComponent(part.rawValue+".json"))}
        } catch {close(fd);fd = -1;throw error}
    }
    deinit {if fd>=0{flock(fd,LOCK_UN);close(fd)}}
    private func check() throws {
        checkLock.lock();defer{checkLock.unlock()}
        try env.check(.productStorage);try plan.check()
        if fd>=0 {
            var held=stat()
            guard fstat(fd,&held)==0,let current=try SafeFiles.attributes(env.paths.root.appendingPathComponent("operation.lock")),held.st_ino==current.st_ino,held.st_dev==current.st_dev,current.st_nlink==1 else{throw ReceiveError.path}
        }
        let now=try env.clock.sample()
        try abNeed(now.utcMS>=last.utcMS && now.monoMS>=last.monoMS,.clockBackward);last=now
        if let localStart {try abNeed(now.monoMS-localStart < plan.contextTiming.localApplyMS,.localProbeTimeout)}
    }
    private func write(_ bytes:Data,to url:URL) throws {
        try check();try SafeFiles.write(bytes,to:url,prepareFile:{u in try self.check();try self.env.protection.created(u);try self.env.protection.verify(u)},checkpoint:{_ in try self.check()});try check()
    }
    private func urls() throws -> [URL] {
        let inv=try SafeFiles.inventory(env.paths.root)
        return [env.paths.root]+(inv.files.union(inv.directories)).sorted().map{env.paths.root.appendingPathComponent($0)}
    }
    private func protectTree(prepare:Bool=true) throws {
        for u in try urls(){
            try check();if prepare{try env.protection.created(u)};try env.protection.verify(u)
            // Flush every new DB/WAL/TXT and directory before writing the aggregate completion.
            let handle=open(u.path,O_RDONLY|O_NOFOLLOW)
            guard handle>=0 else{throw ReceiveError.io}
            let result=fsync(handle);close(handle);guard result==0 else{throw ReceiveError.io};try check()
        }
    }
    private func step(_ name:String) throws {try protectTree(prepare:false);try checkpoint(name);try check()}
    func apply() throws {
        guard operation.try() else{throw ReceiveError.busy};defer{operation.unlock()}
        try check();try require(!attempted,.incomplete);attempted=true;try plan.verify()
        let now=try env.clock.sample()
        try abNeed(now.monoMS>=plan.lastResponseMonoMS && now.monoMS-plan.lastResponseMonoMS < plan.contextTiming.preApplyMS,.preApplyTimeout)
        try plan.beginLocal();localStart=now.monoMS
        let folder=env.paths.texts.appendingPathComponent(projection.root.name)
        try SafeFiles.mkdir(folder);try env.protection.created(folder);try env.protection.verify(folder)
        for d in projection.documents{try write(d.body,to:env.paths.texts.appendingPathComponent(d.localPath))}
        try step("texts")
        try ReceiveProductMetadata.write(projection,url:env.paths.metadata,check:check,prepareFiles:{try self.protectTree()});try step("metadata")
        try autoreleasepool {
            let sql=try ReceiveProductSQL(url:env.paths.syncDB,create:true,check:check)
            try sql.migrate();try protectTree();try step("migrations");try sql.write(projection);try step("baselines")
        }
        try verifyContent();try step("readback")
        try write(completeBytes,to:env.paths.root.appendingPathComponent("complete.json"))
        try step("complete");try verifyContent();completed=true
    }
    private func verifyContent() throws {
        try check();try env.validatePaths()
        try checkpoint("verify:paths")
        let inv=try SafeFiles.inventory(env.paths.root)
        try checkpoint("verify:inventory")
        let required=Set(["operation.lock","identity.json","state","sync.sqlite","metadata/store.sqlite","journal/context.json"])
            .union(LocalStoragePart.allCases.map{"journal/"+$0.rawValue+".json"})
            .union(projection.documents.map{"texts/"+$0.localPath})
        let optional:Set<String>=["complete.json","metadata/store.sqlite-wal","metadata/store.sqlite-shm","sync.sqlite-wal","sync.sqlite-shm"]
        try require(required.isSubset(of:inv.files) && inv.files.isSubset(of:required.union(optional)),.corrupt)
        try require(inv.directories==["metadata","journal","texts","texts/"+projection.root.name],.corrupt)
        for u in try urls(){try env.protection.verify(u)}
        try checkpoint("verify:protection")
        try require(SafeFiles.read(env.paths.identity)==completeBytes && SafeFiles.read(env.paths.root.appendingPathComponent("state"))==Data("preparing\n".utf8),.corrupt)
        try require(SafeFiles.read(env.paths.journal.appendingPathComponent("context.json"))==canonical(plan.context),.corrupt)
        try checkpoint("verify:context")
        for part in LocalStoragePart.allCases {try require(SafeFiles.read(env.paths.journal.appendingPathComponent(part.rawValue+".json"))==plan.parts[part]!, .corrupt)}
        try require(Set(FileManager.default.contentsOfDirectory(atPath:env.paths.texts.path))==[projection.root.name],.corrupt)
        try require(Set(FileManager.default.contentsOfDirectory(atPath:env.paths.texts.appendingPathComponent(projection.root.name).path))==Set(projection.documents.map(\.name)),.corrupt)
        for d in projection.documents{try require(SafeFiles.read(env.paths.texts.appendingPathComponent(d.localPath))==d.body,.body)}
        try checkpoint("verify:texts")
        try ReceiveProductMetadata.verify(projection,url:env.paths.metadata,check:check)
        try checkpoint("verify:metadata")
        try autoreleasepool {try ReceiveProductSQL(url:env.paths.syncDB,create:false,check:check).verify(projection)}
        try check()
    }
    func verifyStored() throws {
        guard operation.try() else{throw ReceiveError.busy};defer{operation.unlock()}
        try check();try require(completed,.incomplete)
        do {try require(SafeFiles.read(env.paths.root.appendingPathComponent("complete.json"))==completeBytes,.corrupt);try verifyContent()}
        catch{completed=false;throw error}
    }
    func verify() async throws {try await Task.detached{try self.verifyStored()}.value}
    func checkPublication() throws {try check();try require(completed,.incomplete)}
    func requireBaseline() throws {throw ReceiveConnectionError.closed}
}

// Explicit app injection point; there is no launch/default UI hook or live activation.
final class ReceiveDedicatedOfflineAppJob:ReceiveAppJob {
    private let coordinator:ReceiveABCoordinator,environment:ReceiveDedicatedEnvironment,execution:ReceiveReviewedExecution
    init(execution:ReceiveReviewedExecution,environment:ReceiveDedicatedEnvironment,executionJournalHome:URL,protocolClass:AnyClass) throws {
        try environment.paths.validate();try environment.check(.productStorage)
        self.environment=environment;self.execution=execution
        coordinator=try .init(offlineReviewed:execution,dedicated:environment,executionJournalHome:executionJournalHome,protocolClass:protocolClass)
    }
    func cancel(){environment.authority?.revoke();coordinator.cancel()}
    func run() async throws -> any ReceiveAppReceipt {
        try await withTaskCancellationHandler(operation:{
            let completion=try await coordinator.run()
            return try await Task.detached{[self] in
                let plan=try ReceiveAdmissionPlan.offline(execution:execution,completion:completion)
                let store=try environment.prepareOffline(plan:plan);try store.apply();return store
            }.value
        },onCancel:{self.cancel()})
    }
}
