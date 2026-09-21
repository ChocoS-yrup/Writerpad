import Foundation
import Darwin

// Synthetic journals only: disposable host workspace or a sealed protected container capability.
final class SyntheticABDiskJournal {
    struct Owner: Codable, Equatable {
        let format: String, workspace: String
    }
    struct Record: Codable {
        let sequence: Int, previous: String, operation: String
        let state: SyntheticABJournalState
    }
    struct Head: Codable, Equatable { let sequence: Int, sha256: String }
    let workspace: URL, root: URL
    private let container: ProtectedBoundaryContainer?
    private let access: PhysicalStorageAccess
    private var format: String { container == nil ? "synthetic-ab-disk-journal-v1" : "synthetic-ab-protected-journal-v1" }
    private var descriptor: Int32 = -1
    private var ownerThread: pthread_t?
    private var rootInode: ino_t = 0, rootDevice: dev_t = 0
    private var lockInode: ino_t = 0
    private(set) var createdHere = false
    private(set) var poisoned = false
    // Internal fault injection for host tests; not a transport or a runtime app hook.
    var checkpoint: (String) throws -> Void = { _ in }
    private let maxRecord = 48*1024*1024, maxTotal = 128*1024*1024
    private let fm = FileManager.default

    init(workspace: URL) throws {
        container = nil; access = PhysicalStorageAccess()
        self.workspace = workspace; root = workspace.appendingPathComponent("execution-journal")
        try validateWorkspace()
    }
    init(container: ProtectedBoundaryContainer) throws {
        self.container = container; access = container.journalAccess
        workspace = container.workspace; root = workspace.appendingPathComponent("execution-journal")
        try validateWorkspace()
    }
    private func validateWorkspace() throws {
        try access.check()
        if let container { try container.validate(workspace); return }
        try SafeFiles.checked(workspace)
        let prefix = "SyntheticABJournal-", name = workspace.lastPathComponent
        try abNeed(workspace.deletingLastPathComponent().path == SafeFiles.temporaryPath() && name.hasPrefix(prefix) && UUID(uuidString:String(name.dropFirst(prefix.count)))?.uuidString.lowercased() == String(name.dropFirst(prefix.count)),.policy)
        guard let info = try SafeFiles.attributes(workspace), info.st_mode & S_IFMT == S_IFDIR else { throw SyntheticABError.policy }
        try abNeed(Set(fm.contentsOfDirectory(atPath:workspace.path)).isSubset(of:["execution-journal"]),.journalCorrupt)
    }
    private func syncDirectory(_ url: URL) throws {
        try access.check(); try access.verify(url)
        let fd = open(url.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW)
        guard fd >= 0 else { throw SyntheticABError.journalWrite }
        defer { close(fd) }
        try abNeed(fsync(fd) == 0,.journalWrite); try access.check()
    }
    func acquire(create: Bool) throws {
        try abNeed(descriptor == -1,.busy)
        createdHere = false
        try validateWorkspace()
        let exists = try SafeFiles.attributes(root) != nil
        if !exists {
            try abNeed(create,.journalCorrupt)
            try abNeed(mkdir(root.path,0o700) == 0,.journalWrite)
            try access.created(root); try access.verify(root); try access.check()
            createdHere = true
            try syncDirectory(workspace)
            try checkpoint("created-root")
        }
        try SafeFiles.checked(root); try access.verify(root); try access.check()
        guard let ri = try SafeFiles.attributes(root), ri.st_mode & S_IFMT == S_IFDIR, ri.st_mode & 0o777 == 0o700 else { throw SyntheticABError.journalCorrupt }
        let lockURL = root.appendingPathComponent("lock")
        try SafeFiles.checked(lockURL); try access.check()
        if exists { try access.verify(lockURL) }
        let flags = O_RDWR|O_NOFOLLOW|(exists ? 0 : O_CREAT|O_EXCL)
        let fd = open(lockURL.path,flags,0o600)
        guard fd >= 0 else { throw SyntheticABError.journalCorrupt }
        do {
            if !exists { try access.created(lockURL) }
            try access.verify(lockURL); try access.check()
        } catch { close(fd); throw error }
        var li = stat()
        guard fstat(fd,&li) == 0, li.st_mode & S_IFMT == S_IFREG, li.st_nlink == 1, li.st_size == 0, li.st_mode & 0o777 == 0o600 else { close(fd); throw SyntheticABError.journalCorrupt }
        guard flock(fd,LOCK_EX|LOCK_NB) == 0 else { close(fd); throw SyntheticABError.busy }
        descriptor = fd; ownerThread = pthread_self(); rootInode = ri.st_ino; rootDevice = ri.st_dev; lockInode = li.st_ino
        do {
            try anchored()
            if !exists {
                try abNeed(fsync(fd) == 0,.journalWrite); try syncDirectory(root)
                try checkpoint("locked-new")
                let owner = Owner(format:format,workspace:workspace.path)
                try publish(try canonical(owner),name:"owner.json",operation:"initialize")
                try append(SyntheticABJournalState(),operation:"initialize",previous:nil)
            }
            _ = try load()
        } catch { release(); throw error }
    }
    func release() {
        guard descriptor >= 0, let thread = ownerThread, pthread_equal(thread,pthread_self()) != 0 else { return }
        _ = flock(descriptor,LOCK_UN); close(descriptor); descriptor = -1; ownerThread = nil
    }
    private func anchored() throws {
        try abNeed(descriptor >= 0 && ownerThread.map { pthread_equal($0,pthread_self()) != 0 } == true,.busy)
        try validateWorkspace(); try SafeFiles.checked(root)
        try access.verify(root); try access.verify(root.appendingPathComponent("lock")); try access.check()
        guard let ri = try SafeFiles.attributes(root), let li = try SafeFiles.attributes(root.appendingPathComponent("lock")) else { throw SyntheticABError.journalCorrupt }
        try abNeed(ri.st_ino == rootInode && ri.st_dev == rootDevice && ri.st_mode & S_IFMT == S_IFDIR && ri.st_mode & 0o777 == 0o700 && li.st_ino == lockInode && li.st_dev == rootDevice && li.st_nlink == 1 && li.st_size == 0 && li.st_mode & S_IFMT == S_IFREG && li.st_mode & 0o777 == 0o600,.journalCorrupt)
    }
    private func filename(_ n: Int) -> String { String(format:"record-%03d.json",n) }
    private func readFile(_ name: String,limit: Int) throws -> Data {
        try access.check()
        let url = root.appendingPathComponent(name)
        try access.verify(url)
        guard let info = try SafeFiles.attributes(url), info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600 else { throw SyntheticABError.journalCorrupt }
        let bytes = try SafeFiles.read(url,limit:limit)
        try access.verify(url); try access.check()
        return bytes
    }
    private func publish(_ bytes: Data,name: String,operation: String,replace: Bool = false) throws {
        try anchored()
        let url = root.appendingPathComponent(name)
        if !replace { try abNeed(try SafeFiles.attributes(url) == nil,.journalCorrupt) }
        try checkpoint("before:\(operation):\(name)")
        try access.check()
        try SafeFiles.write(bytes,to:url,prepareFile:{ pending in
            try self.access.check(); try self.access.created(pending); try self.access.verify(pending)
            try self.checkpoint("protected:\(operation):\(name)")
            try self.access.verify(pending); try self.access.check()
        },checkpoint:{ _ in
            try self.access.check(); try self.access.verify(url.appendingPathExtension("pending"))
            try self.checkpoint("pending:\(operation):\(name)"); try self.access.check()
        })
        try access.check(); try access.verify(url)
        try checkpoint("published:\(operation):\(name)"); try access.check()
        try abNeed(try readFile(name,limit:maxRecord) == bytes,.journalReadback)
    }
    private func load() throws -> (Head,SyntheticABJournalState) {
        try anchored()
        let names = try fm.contentsOfDirectory(atPath:root.path)
        try abNeed(names.count <= 68,.journalCorrupt)
        let owner = try decodeExact(Owner.self,readFile("owner.json",limit:4096))
        try abNeed(owner == Owner(format:format,workspace:workspace.path),.journalCorrupt)
        let head = try decodeExact(Head.self,readFile("head.json",limit:4096))
        try abNeed((0...63).contains(head.sequence),.journalCorrupt)
        let allowed = Set(["lock","owner.json","head.json"]+(0...head.sequence).map(filename))
        try abNeed(Set(names) == allowed,.journalCorrupt) // Includes pending, orphan and foreign files.
        var previous: SyntheticABJournalState?, hash = "", total = 0
        for n in 0...head.sequence {
            let url = root.appendingPathComponent(filename(n))
            guard let info = try SafeFiles.attributes(url), info.st_size >= 0, info.st_size <= maxRecord else { throw SyntheticABError.journalCorrupt }
            total = try abAdd(total,Int(info.st_size)); try abNeed(total <= maxTotal,.journalCorrupt)
            let data = try readFile(filename(n),limit:maxRecord)
            let record = try decodeExact(Record.self,data)
            try abNeed(record.sequence == n && record.previous == hash,.journalCorrupt)
            _ = try SyntheticABJournal(restored:canonical(record.state)).read()
            if let previous { try Self.transition(previous,record.state,operation:record.operation) }
            else { try abNeed(record.operation == "initialize" && record.state == SyntheticABJournalState(),.journalCorrupt) }
            previous = record.state; hash = byteHash(data)
        }
        try abNeed(hash == head.sha256,.journalCorrupt)
        try access.check()
        return (head,previous!)
    }
    // Replay each allowed mutation; no field can disappear, no counter can be refunded.
    static func transition(_ old: SyntheticABJournalState,_ new: SyntheticABJournalState,operation: String) throws {
        var expected = old
        if operation == "claim" {
            try abNeed(old == SyntheticABJournalState() && new.runID != nil && new.binding != nil,.journalCorrupt)
            guard let context = new.context else { throw SyntheticABError.journalCorrupt }
            try context.validate(runID:new.runID!); try abNeed(context.journalBinding == new.binding,.journalCorrupt)
            expected.runID = new.runID; expected.binding = new.binding; expected.context = context; expected.status = "running"
        } else {
            try abNeed(old.status == "running",.journalCorrupt)
            let parts = operation.split(separator:":").map(String.init)
            if parts.count == 2, let n = Int(parts[1]), (1...14).contains(n), parts[1] == String(n) {
                let index = n-1
                switch parts[0] {
                case "reserve":
                    try abNeed(old.httpUsed == index && old.events.count == index && new.events.count == n && (old.events.last?.verifiedMonoMS != nil || index == 0),.journalCorrupt)
                    let event = new.events[index]
                    guard let runID = new.runID else { throw SyntheticABError.journalCorrupt }
                    let prefix = "synthetic-ab-", suffix = String(runID.dropFirst("synthetic-ab-".count))
                    try abNeed(runID.hasPrefix(prefix) && UUID(uuidString:suffix)?.uuidString.lowercased() == suffix,.journalCorrupt)
                    let request = try SyntheticABRunner.request(index,project:new.context?.reviewed?.project ?? SyntheticABExpected.fixture().project)
                    let reservation = SyntheticABEvent(request:request,reservationID:runID+":\(n)",phase:request.phase,reservedUTCMS:event.reservedUTCMS,reservedMonoMS:event.reservedMonoMS)
                    try abNeed(event == reservation && event.reservedUTCMS != nil && event.reservedMonoMS != nil,.journalCorrupt)
                    expected.httpUsed += 1; if index%7 == 0 { expected.authUsed += 1 }; expected.events.append(event)
                case "start", "metadata", "response":
                    try abNeed(old.httpUsed == n && old.events.count == n && new.events.count == n,.journalCorrupt)
                    let e = new.events[index]
                    if parts[0] == "start" {
                        try abNeed(old.events[index].startedMonoMS == nil && e.startedMonoMS != nil && e.startedUTCMS != nil,.journalCorrupt)
                        expected.events[index].startedMonoMS = e.startedMonoMS; expected.events[index].startedUTCMS = e.startedUTCMS
                    } else if parts[0] == "metadata" {
                        try abNeed(old.events[index].startedMonoMS != nil && old.events[index].receivedMonoMS == nil && e.receivedMonoMS != nil && e.receivedUTCMS != nil && e.status != nil && e.sha256?.count == 64 && e.byteCount != nil,.journalCorrupt)
                        expected.events[index].receivedMonoMS = e.receivedMonoMS; expected.events[index].receivedUTCMS = e.receivedUTCMS
                        expected.events[index].status = e.status; expected.events[index].sha256 = e.sha256; expected.events[index].byteCount = e.byteCount
                    } else {
                        try abNeed(old.events[index].receivedMonoMS != nil && old.events[index].verifiedMonoMS == nil && e.verifiedMonoMS != nil && e.verifiedUTCMS != nil && e.raw != nil,.journalCorrupt)
                        expected.events[index].verifiedMonoMS = e.verifiedMonoMS; expected.events[index].verifiedUTCMS = e.verifiedUTCMS
                        expected.events[index].raw = e.raw; expected.events[index].contentRange = e.contentRange; expected.events[index].rowCount = e.rowCount
                    }
                default: throw SyntheticABError.journalCorrupt
                }
            } else if operation == "local_start" {
                try abNeed(old.httpUsed == 14 && old.events.count == 14 && old.events.last?.verifiedMonoMS != nil && new.events.count == 15,.journalCorrupt)
                let e = new.events[14]
                try abNeed(e.startedMonoMS != nil && e.startedUTCMS != nil && e == SyntheticABEvent(phase:"local_policy_probe",startedUTCMS:e.startedUTCMS,startedMonoMS:e.startedMonoMS),.journalCorrupt)
                expected.events.append(e)
            } else if operation == "finish" {
                try abNeed(old.events.count == 15 && new.events.count == 15 && new.events[14].completedMonoMS != nil && new.events[14].completedUTCMS != nil,.journalCorrupt)
                expected.events[14].completedMonoMS = new.events[14].completedMonoMS; expected.events[14].completedUTCMS = new.events[14].completedUTCMS; expected.status = "finished"
            } else if operation == "stop" { expected.status = "stopped" }
            else { throw SyntheticABError.journalCorrupt }
        }
        try abNeed(expected == new,.journalCorrupt)
        for e in new.events {
            let mono = [e.reservedMonoMS,e.startedMonoMS,e.receivedMonoMS,e.verifiedMonoMS,e.completedMonoMS].compactMap { $0 }
            let utc = [e.reservedUTCMS,e.startedUTCMS,e.receivedUTCMS,e.verifiedUTCMS,e.completedUTCMS].compactMap { $0 }
            for v in mono+utc { try abInteger(v) }
            try abNeed(mono == mono.sorted() && utc == utc.sorted(),.journalCorrupt)
            if let size = e.byteCount { try abNeed((0...4*1024*1024).contains(size),.journalCorrupt) }
        }
    }
    private func append(_ state: SyntheticABJournalState,operation: String,previous: Head?) throws {
        let sequence = (previous?.sequence ?? -1)+1
        try abNeed(sequence <= 63,.quota)
        let record = Record(sequence:sequence,previous:previous?.sha256 ?? "",operation:operation,state:state)
        let bytes = try canonical(record)
        try abNeed(bytes.count <= maxRecord,.journalWrite)
        var total = bytes.count
        for n in 0..<sequence {
            guard let a = try SafeFiles.attributes(root.appendingPathComponent(filename(n))) else { throw SyntheticABError.journalCorrupt }
            total = try abAdd(total,Int(a.st_size))
        }
        try abNeed(total <= maxTotal,.journalWrite)
        try publish(bytes,name:filename(sequence),operation:operation)
        try publish(try canonical(Head(sequence:sequence,sha256:byteHash(bytes))),name:"head.json",operation:operation,replace:previous != nil)
        let result = try load()
        try abNeed(result.0.sequence == sequence && result.1 == state,.journalReadback)
        try checkpoint("committed:\(operation)"); try access.check()
    }
    func read() throws -> SyntheticABJournalState {
        if descriptor >= 0 { return try load().1 }
        try acquire(create:false); defer { release() }
        return try load().1
    }
    func write(_ state: SyntheticABJournalState,operation: String) throws {
        try abNeed(!poisoned,.journalPoisoned)
        do {
            let (head,old) = try load()
            try Self.transition(old,state,operation:operation)
            try append(state,operation:operation,previous:head)
        } catch { poisoned = true; throw error }
    }
}

#if os(macOS)
// Narrow host subprocess harness: fixed synthetic inputs, no credentials or real transport.
public enum SyntheticABJournalProbe {
    public static func run(workspace: URL,checkpoint: String,mode: String) throws {
        try abNeed(["run","crash","hold"].contains(mode),.policy)
        let disk = try SyntheticABDiskJournal(workspace:workspace)
        disk.checkpoint = { point in
            guard point == checkpoint else { return }
            if mode == "crash" { _exit(73) }
            if mode == "hold" {
                FileHandle.standardOutput.write(Data("LOCKED\n".utf8))
                var b: UInt8 = 0; _ = Darwin.read(STDIN_FILENO,&b,1)
            }
        }
        let expected = SyntheticABExpected.fixture()
        let runner = try SyntheticABRunner(expected:expected,timing:.fixture,runID:"synthetic-ab-ee260914-0000-4000-8000-000000009200")
        let journal = try SyntheticABJournal(disk:disk)
        let completion = try runner.run(transport:SyntheticABTransport(expected.responses()+expected.responses()),journal:journal,environment:SyntheticABEnvironment())
        FileHandle.standardOutput.write(try canonical(completion.checkedReport()))
    }
}
#endif
