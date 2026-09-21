import Foundation
import Darwin

public struct ReceiveEditableSnapshot: Sendable {
    public struct Document: Identifiable, Sendable {
        public let id: UUID
        public let name: String
        public let text: String
        public let revision: Int
    }
    public let sourceRun: String
    public let folderName: String
    public let documents: [Document]
}

/// A stable, revalidated view of the retained source and editable files.
/// Raw container paths and file contents do not escape this boundary.
struct ReceiveEditablePromotionInput {
    let localID: UUID
    let source: ReceiveStoredSnapshot
    let editable: ReceiveEditableSnapshot
    let identitySHA256: String
    let workspaceSHA256: String
}

struct ReceiveEditableDrafts: Sendable {
    private var values: [UUID:String] = [:]
    init(snapshot:ReceiveEditableSnapshot?=nil) {
        if let snapshot { values=Dictionary(uniqueKeysWithValues:snapshot.documents.map{($0.id,$0.text)}) }
    }
    func text(for document:ReceiveEditableSnapshot.Document)->String { values[document.id] ?? document.text }
    mutating func set(_ text:String,for id:UUID) { values[id]=text }
    func isDirty(_ document:ReceiveEditableSnapshot.Document)->Bool { text(for:document) != document.text }
    func dirtyCount(in snapshot:ReceiveEditableSnapshot)->Int { snapshot.documents.filter(isDirty).count }
    func all(in snapshot:ReceiveEditableSnapshot)->[UUID:String] {
        Dictionary(uniqueKeysWithValues:snapshot.documents.map{($0.id,text(for:$0))})
    }
}

enum ReceiveEditableStatus {
    static func saveFailure(_ error:Error)->String {
        switch error as? ReceiveError {
        case .busy: return "로컬 저장 차단 · 다른 저장이 진행 중이거나 revision이 변경됐습니다"
        case .body: return "로컬 저장 차단 · 본문 크기 또는 UTF-8을 확인하세요"
        case .identity: return "로컬 저장 차단 · 원본 결합 정보를 다시 확인하세요"
        case .path,.structure,.corrupt,.incomplete: return "로컬 저장 차단 · 작업 사본 검증에 실패했습니다"
        case .io: return "로컬 저장 차단 · 파일 저장을 완료하지 못했습니다"
        default: return "로컬 저장 차단 · 마지막 완료본을 유지합니다"
        }
    }
}

/// Isolated local state. Body and save journal share one atomic canonical file.
enum ReceiveEditableCopy {
    private static let format = "receive-editable-copy-v1"
    private static let maximumDocumentBytes = 4 * 1024 * 1024
    private static let maximumWorkspaceBytes = 16 * 1024 * 1024
    private struct Entry: Codable, Equatable { let id:String,name:String;let bytes:Int;let sha256:String }
    private struct Identity: Codable, Equatable { let format:String,local:String,sourceRun:String,folder:String;let documents:[Entry] }
    private struct Save: Codable, Equatable { let revision:Int,previousSHA256:String,sha256:String,bytes:Int }
    private struct WorkingDocument: Codable, Equatable {
        let id:String,name:String,baseSHA256:String
        var text:String,revision:Int,sha256:String,saves:[Save]
    }
    private struct Workspace: Codable, Equatable { let format:String,sourceRun:String;var documents:[WorkingDocument] }

    static func create(home:URL,local:UUID,snapshot:ReceiveStoredSnapshot,check:()throws->Void)throws->URL {
        try check();try SafeFiles.checked(home)
        guard UUID(uuidString:snapshot.runID)?.uuidString.lowercased()==snapshot.runID,!snapshot.documents.isEmpty else{throw ReceiveError.identity}
        let localRoot=home.appendingPathComponent("Library/Application Support/ReceiveEditable-v1/"+local.uuidString.lowercased(),isDirectory:true)
        let destination=localRoot.appendingPathComponent(snapshot.runID,isDirectory:true)
        try SafeFiles.mkdir(localRoot);guard try SafeFiles.attributes(destination)==nil else{throw ReceiveError.existingData}
        let staging=localRoot.appendingPathComponent("."+snapshot.runID+".staging",isDirectory:true)
        guard try SafeFiles.attributes(staging)==nil else{throw ReceiveError.existingData};try SafeFiles.mkdir(staging)
        let identity=try expectedIdentity(local:local,snapshot:snapshot),entries=identity.documents
        let workspace=Workspace(format:format,sourceRun:snapshot.runID,documents:entries.map{entry in
            let source=snapshot.documents.first{$0.id.uuidString.lowercased()==entry.id}!
            return .init(id:entry.id,name:entry.name,baseSHA256:entry.sha256,text:source.text,revision:0,sha256:entry.sha256,saves:[])
        })
        try SafeFiles.write(Data(),to:staging.appendingPathComponent("operation.lock"),checkpoint:{_ in try check()})
        try SafeFiles.write(try canonical(identity),to:staging.appendingPathComponent("identity.json"),checkpoint:{_ in try check()})
        try SafeFiles.write(try canonical(workspace),to:staging.appendingPathComponent("workspace.json"),checkpoint:{_ in try check()})
        _=try validate(root:staging,expected:identity,check:check)
        guard rename(staging.path,destination.path)==0 else{throw ReceiveError.io}
        let fd=Darwin.open(localRoot.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);guard fd>=0 else{throw ReceiveError.io};defer{close(fd)}
        guard fsync(fd)==0 else{throw ReceiveError.io};_=try validate(root:destination,expected:identity,check:check);return destination
    }

    static func open(home:URL,local:UUID,snapshot source:ReceiveStoredSnapshot,check:()throws->Void)throws->ReceiveEditableSnapshot {
        let identity=try expectedIdentity(local:local,snapshot:source)
        let root=try location(home:home,local:local,sourceRun:source.runID)
        return snapshot(try validate(root:root,expected:identity,check:check),identity)
    }

    /// Revalidates the retained source binding while holding the editable
    /// operation lock, then captures hashes of the canonical files used by a
    /// promotion package. This is read-only and never advances a revision.
    static func promotionInput(
        home: URL,
        local: UUID,
        snapshot source: ReceiveStoredSnapshot,
        check: () throws -> Void
    ) throws -> ReceiveEditablePromotionInput {
        let identity = try expectedIdentity(local: local, snapshot: source)
        let root = try location(home: home, local: local, sourceRun: source.runID)
        return try withExclusiveLock(root: root) {
            let workspace = try validate(root: root, expected: identity, check: check)
            let identityBytes = try SafeFiles.read(
                root.appendingPathComponent("identity.json"),
                limit: 64 * 1024
            )
            let workspaceBytes = try SafeFiles.read(
                root.appendingPathComponent("workspace.json"),
                limit: maximumWorkspaceBytes
            )
            try require(try decodeExact(Identity.self, identityBytes) == identity, .identity)
            try require(try decodeExact(Workspace.self, workspaceBytes) == workspace, .corrupt)
            try check()
            return ReceiveEditablePromotionInput(
                localID: local,
                source: source,
                editable: snapshot(workspace, identity),
                identitySHA256: byteHash(identityBytes),
                workspaceSHA256: byteHash(workspaceBytes)
            )
        }
    }

    static func save(home:URL,local:UUID,snapshot source:ReceiveStoredSnapshot,documentID:UUID,expectedRevision:Int,text:String,check:()throws->Void)throws->ReceiveEditableSnapshot {
        let identity=try expectedIdentity(local:local,snapshot:source)
        let root=try location(home:home,local:local,sourceRun:source.runID)
        return try withExclusiveLock(root:root) {
            var workspace=try validate(root:root,expected:identity,check:check)
            guard let index=workspace.documents.firstIndex(where:{$0.id==documentID.uuidString.lowercased()}),workspace.documents[index].revision==expectedRevision else{throw ReceiveError.busy}
            let bytes=Data(text.utf8);try require(bytes.count<=maximumDocumentBytes && String(data:bytes,encoding:.utf8) != nil,.body)
            let previous=workspace.documents[index].sha256,newHash=byteHash(bytes),revision=expectedRevision+1
            workspace.documents[index].text=text;workspace.documents[index].revision=revision;workspace.documents[index].sha256=newHash
            workspace.documents[index].saves.append(.init(revision:revision,previousSHA256:previous,sha256:newHash,bytes:bytes.count))
            try check();let encoded=try canonical(workspace);try require(encoded.count<=maximumWorkspaceBytes,.body)
            try SafeFiles.write(encoded,to:root.appendingPathComponent("workspace.json"),checkpoint:{_ in try check()})
            return snapshot(try validate(root:root,expected:identity,check:check),identity)
        }
    }

    private static func location(home:URL,local:UUID,sourceRun:String)throws->URL {
        try SafeFiles.checked(home)
        guard UUID(uuidString:sourceRun)?.uuidString.lowercased()==sourceRun else{throw ReceiveError.identity}
        let root=home.appendingPathComponent("Library/Application Support/ReceiveEditable-v1/"+local.uuidString.lowercased()+"/"+sourceRun,isDirectory:true)
        try SafeFiles.checked(root);return root
    }
    private static func expectedIdentity(local:UUID,snapshot:ReceiveStoredSnapshot)throws->Identity {
        guard UUID(uuidString:snapshot.runID)?.uuidString.lowercased()==snapshot.runID,!snapshot.documents.isEmpty else{throw ReceiveError.identity}
        return .init(format:format,local:local.uuidString.lowercased(),sourceRun:snapshot.runID,folder:snapshot.folderName,documents:try sourceEntries(snapshot))
    }
    private static func sourceEntries(_ snapshot:ReceiveStoredSnapshot)throws->[Entry] {
        try require(Set(snapshot.documents.map(\.id)).count==snapshot.documents.count,.identity)
        return try snapshot.documents.map{document in
            try validateComponent(document.name);let bytes=Data(document.text.utf8)
            try require(bytes.count==document.byteCount && bytes.count<=maximumDocumentBytes,.body)
            return .init(id:document.id.uuidString.lowercased(),name:document.name,bytes:bytes.count,sha256:byteHash(bytes))
        }.sorted{$0.id<$1.id}
    }
    private static func validate(root:URL,expected:Identity,check:()throws->Void)throws->Workspace {
        try check();let inventory=try SafeFiles.inventory(root)
        try require(inventory.files==["identity.json","operation.lock","workspace.json"] && inventory.directories.isEmpty,.structure)
        guard let lock=try SafeFiles.attributes(root.appendingPathComponent("operation.lock")),lock.st_mode&S_IFMT==S_IFREG,lock.st_nlink==1,lock.st_size==0 else{throw ReceiveError.path}
        let identity=try decodeExact(Identity.self,SafeFiles.read(root.appendingPathComponent("identity.json"),limit:64*1024));try require(identity==expected,.identity)
        let workspace=try decodeExact(Workspace.self,SafeFiles.read(root.appendingPathComponent("workspace.json"),limit:maximumWorkspaceBytes))
        try require(workspace.format==format && workspace.sourceRun==expected.sourceRun && workspace.documents.count==expected.documents.count,.identity)
        for (document,base) in zip(workspace.documents,expected.documents) {
            let bytes=Data(document.text.utf8)
            try require(document.id==base.id && document.name==base.name && document.baseSHA256==base.sha256 && byteHash(bytes)==document.sha256 && bytes.count<=maximumDocumentBytes,.body)
            try require(document.revision==document.saves.count,.corrupt);var hash=base.sha256
            for (offset,save) in document.saves.enumerated(){try require(save.revision==offset+1 && save.previousSHA256==hash,.corrupt);hash=save.sha256}
            try require(hash==document.sha256 && (document.saves.last?.bytes ?? base.bytes)==bytes.count,.corrupt)
        }
        try check();return workspace
    }
    private static func withExclusiveLock<T>(root:URL,_ body:()throws->T)throws->T {
        let file=root.appendingPathComponent("operation.lock");try SafeFiles.checked(file)
        let fd=Darwin.open(file.path,O_RDWR|O_NOFOLLOW);guard fd>=0 else{throw ReceiveError.io};defer{close(fd)}
        guard flock(fd,LOCK_EX|LOCK_NB)==0 else{throw ReceiveError.busy};defer{flock(fd,LOCK_UN)}
        var held=stat();guard fstat(fd,&held)==0,let current=try SafeFiles.attributes(file),held.st_ino==current.st_ino,held.st_dev==current.st_dev,current.st_mode&S_IFMT==S_IFREG,current.st_nlink==1,current.st_size==0 else{throw ReceiveError.path}
        return try body()
    }
    private static func snapshot(_ workspace:Workspace,_ identity:Identity)->ReceiveEditableSnapshot {
        .init(sourceRun:identity.sourceRun,folderName:identity.folder,documents:workspace.documents.map{.init(id:UUID(uuidString:$0.id)!,name:$0.name,text:$0.text,revision:$0.revision)})
    }
}
