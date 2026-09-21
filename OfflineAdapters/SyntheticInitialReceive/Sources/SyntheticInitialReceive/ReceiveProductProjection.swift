import Foundation

// Typed projection of members. Possession of this value grants no write access.
struct ReceiveProductProjection {
    struct Document { let id:UUID, parent:UUID, name:String, localPath:String, remotePath:String, revision:Int, structureRevision:Int, updated:String, body:Data, hash:String }
    struct Folder { let id:UUID, remoteParent:UUID?, name:String, revision:Int, updated:String }
    struct Order { let id:UUID, parent:UUID, children:[UUID], revision:Int, updated:String }
    let local:UUID, project:UUID, account:UUID, root:Folder, documents:[Document], order:Order
    let parts:[LocalStoragePart:Data]
    init(parts:[LocalStoragePart:Data],local:UUID,project:UUID,account:UUID) throws {
        self.parts=parts;self.local=local;self.project=project;self.account=account
        func values(_ key:LocalStoragePart) throws -> [WindowsJSON] {guard let bytes=parts[key] else {throw WindowsReaderError.shape};return try WindowsJSON.decode(bytes).array()}
        func id(_ row:WindowsJSON,_ key:String) throws -> UUID {guard let value=UUID(uuidString:try row.str(key)) else{throw WindowsReaderError.shape};return value}
        func parent(_ row:WindowsJSON) throws -> UUID? {if try row.get("parent_folder_id") == .null{return nil};return try id(row,"parent_folder_id")}
        func common(_ row:WindowsJSON) throws {try wrNeed(id(row,"project_id")==project,.binding);try WindowsHandoffReader.date(row.get("updated_at"));try wrNeed(row.get("revision").int()>0,.shape)}
        func name(_ row:WindowsJSON) throws -> String {let s=try row.str("name");try wrNeed(!s.isEmpty && s != "." && s != ".." && !s.contains("/") && !s.contains("\\") && !s.utf8.contains(0),.shape);try validateComponent(s);return s}
        let folders=try values(.folderBaseline),orders=try values(.treeOrderBaseline)
        try wrNeed(folders.count==1 && orders.count==1,.shape)
        let f=folders[0];try common(f);try wrNeed(f.get("is_deleted") == .bool(false) && f.get("deleted_at") == .null,.shape)
        root=try Folder(id:id(f,"folder_id"),remoteParent:parent(f),name:name(f),revision:f.get("revision").int(),updated:f.str("updated_at"))
        try wrNeed(root.remoteParent != root.id,.shape)
        let o=orders[0];try common(o);try wrNeed(parent(o)==root.id,.shape)
        let children=try o.get("children").array().map{v -> UUID in guard case let .string(s)=v,let u=UUID(uuidString:s) else {throw WindowsReaderError.shape};return u}
        order=try Order(id:id(o,"tree_order_id"),parent:root.id,children:children,revision:o.get("revision").int(),updated:o.str("updated_at"))
        guard let bodiesData=parts[.bodies] else{throw WindowsReaderError.shape}
        let bodies=try JSONDecoder().decode([String:Data].self,from:bodiesData)
        var docs:[Document]=[],meta:[WindowsJSON]=[f]
        for wrapper in try values(.documentBaseline) {
            let d=try wrapper.get("row");try common(d)
            let did=try id(d,"document_id"),n=try name(d)
            guard let bytes=bodies[did.uuidString.lowercased()],String(data:bytes,encoding:.utf8) != nil else {throw WindowsReaderError.body}
            try wrNeed(parent(d)==root.id && d.get("is_deleted") == .bool(false) && d.get("deleted_at") == .null,.shape)
            try wrNeed(byteHash(bytes)==wrapper.str("body_sha256") && bytes.count==wrapper.get("body_bytes").int() && d.get("structure_revision").int()>0,.body)
            let remote=try d.str("relative_path");try wrNeed(!remote.isEmpty && !remote.hasPrefix("/") && !remote.split(separator:"/").contains(".."),.shape)
            docs.append(try .init(id:did,parent:root.id,name:n,localPath:root.name+"/"+n,remotePath:remote,revision:d.get("revision").int(),structureRevision:d.get("structure_revision").int(),updated:d.str("updated_at"),body:bytes,hash:byteHash(bytes)));meta.append(d)
        }
        try wrNeed(docs.count==2 && Set(docs.map(\.id)).count==docs.count && Set(docs.map{$0.localPath.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX"))}).count==docs.count,.shape)
        try wrNeed(Set(children)==Set(docs.map(\.id)) && children.count==docs.count && bodies.count==docs.count,.shape)
        let allIDs=[root.id,order.id]+docs.map(\.id);try wrNeed(Set(allIDs).count==allIDs.count && !allIDs.contains(local) && local != project && local != account,.binding)
        let actual=try values(.metadata).map{$0.encoded().base64EncodedString()}.sorted()
        try wrNeed(actual==meta.map{$0.encoded().base64EncodedString()}.sorted(),.shape)
        documents=docs.sorted{$0.id.uuidString < $1.id.uuidString}
    }
    static func date(_ value:String) throws -> Date {
        try WindowsHandoffReader.date(.string(value))
        let pattern = #"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,6}))?(Z|[+-][0-9]{2}:[0-9]{2})$"#
        let re=try NSRegularExpression(pattern:pattern),m=re.firstMatch(in:value,range:NSRange(value.startIndex...,in:value))!
        func field(_ i:Int)->String{Range(m.range(at:i),in:value).map{String(value[$0])} ?? ""}
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(secondsFromGMT:0)!
        let base=calendar.date(from:DateComponents(year:Int(field(1)),month:Int(field(2)),day:Int(field(3)),hour:Int(field(4)),minute:Int(field(5)),second:Int(field(6))))!
        let zone=field(8);var offset=0
        if zone != "Z" {let parts=zone.dropFirst().split(separator:":");offset=(Int(parts[0])!*3600+Int(parts[1])!*60)*(zone.first=="-" ? -1:1)}
        let fraction=field(7).isEmpty ? 0:Double("0."+field(7))!
        // Date stores a binary instant; the exact original string remains in SQL and provenance.
        return base.addingTimeInterval(fraction-Double(offset))
    }
}

// Historical local snapshot only. No receipt, session, grant, or writable store escapes.
public struct ReceiveStoredSnapshot {
    public struct Document:Identifiable {
        public let id:UUID, name:String, text:String, byteCount:Int
    }
    public let runID:String, folderName:String, documents:[Document]
}

enum ReceiveStoredReader {
    static func read(home:URL,local:UUID,target:ReviewedReceiveTarget,check:@escaping ()throws->Void) throws -> ReceiveStoredSnapshot {
        try check();try SafeFiles.checked(home)
        let parent=home.appendingPathComponent("Library/Application Support/ReceiveDedicated-v1")
        let root=parent.appendingPathComponent(local.uuidString.lowercased())
        let inventory=try SafeFiles.inventory(root)
        var files:[String:Data]=[:],total=0
        for name in inventory.files.sorted() {
            try check()
            let bytes=try SafeFiles.read(root.appendingPathComponent(name),limit:32*1024*1024)
            total=try abAdd(total,bytes.count);try wrNeed(total<=128*1024*1024,.size);files[name]=bytes
        }
        func data(_ name:String)throws->Data {guard let value=files[name] else{throw WindowsReaderError.file};return value}
        func decode<T:Decodable>(_ type:T.Type,_ bytes:Data)throws->T {
            _ = try WindowsJSON.decode(bytes) // Reject duplicate JSON keys before Codable.
            return try JSONDecoder().decode(type,from:bytes)
        }
        let context=try decode(ReceiveReviewedJournalBinding.self,data("journal/context.json"))
        guard let run=UUID(uuidString:context.runID) else {throw WindowsReaderError.binding}
        try wrNeed(run.uuidString.lowercased()==context.runID && context.mode==(target.binding.str("endpoint")=="https://synthetic.invalid" ? "offline-reviewed-comparison-v1":"authorized-live-v1") && context.localProjectID==local.uuidString.lowercased() && context.bundleID==ProtectedBoundaryContainer.bundleID,.binding)
        try wrNeed(context.endpoint==target.binding.str("endpoint") && context.account==target.binding.str("account_id") && context.project==target.binding.str("project_id") && context.sourceRun==target.sourceRun && context.handoffSHA256==target.review.handoff_sha256 && context.targetSHA256==target.targetSHA256,.binding)
        try wrNeed(context.httpLimit==14 && context.authLimit==2,.contract)
        let journal=parent.appendingPathComponent("execution-"+run.uuidString.lowercased())
        let journalInventory=try SafeFiles.inventory(journal)
        try wrNeed(journalInventory.files==["run.json","run.lock"] && journalInventory.directories.isEmpty,.shape)
        let ledgerBytes=try SafeFiles.read(journal.appendingPathComponent("run.json"),limit:64*1024*1024)
        let ledger=try decode(ReceiveAuthorizedRun.Ledger.self,ledgerBytes)
        try wrNeed(ledgerBytes==canonical(ledger) && data("journal/context.json")==canonical(context),.shape)
        try wrNeed(ledger.context==context && ledger.kind=="ipad-authorized-ab-ledger-v1" && ledger.status=="finished" && ledger.httpUsed==14 && ledger.authUsed==2 && ledger.events.count==14,.binding)
        try ledger.timing.validate()
        let expected=try SyntheticABExpected.reviewedComparison(target)
        var passes:[[WindowsJSON]]=[[],[]],responseBytes=0,last=ledger.start
        for (index,event) in ledger.events.enumerated() {
            try check()
            guard let start=event.started,let received=event.received,let verified=event.verified,let raw=event.raw,let status=event.status else {throw WindowsReaderError.evidence}
            try wrNeed(event.ordinal==index && byteHash(raw)==event.sha256 && raw.count<=ledger.timing.maxResponseBytes,.hash)
            responseBytes=try abAdd(responseBytes,raw.count);try wrNeed(responseBytes<=ledger.timing.maxRunBytes,.size)
            for stamp in [event.reserved,start,received,verified] {
                try abInteger(stamp.utcMS);try abInteger(stamp.monoMS)
                try wrNeed(stamp.utcMS>=last.utcMS && stamp.monoMS>=last.monoMS && stamp.utcMS<ledger.timing.expiresUTCMS && stamp.utcMS<context.sessionExpiresUTCMS,.evidence)
                last=stamp
            }
            try wrNeed(verified.monoMS-event.reserved.monoMS<ledger.timing.requestMS && verified.monoMS-ledger.start.monoMS<ledger.timing.totalMS,.evidence)
            if index%7==6 {try wrNeed(verified.monoMS-ledger.events[index-6].reserved.monoMS<ledger.timing.passMS,.evidence)}
            if index==7 {try wrNeed(start.monoMS-ledger.events[6].received!.monoMS<ledger.timing.interpassMS,.evidence)}
            let value=try expected.validateResponse(index%7,.init(raw:raw,status:status,contentRange:event.range,delayMS:0))
            if index%7>=2 {try wrNeed(event.rows==value.array().count,.evidence)}
            passes[index/7].append(value)
        }
        try wrNeed(expected.validatePass(passes[0])==expected.validatePass(passes[1]),.evidence)
        let expectedParts=try ReceiveAdmissionPlan.memberParts(target:target,values:passes[1])
        var parts:[LocalStoragePart:Data]=[:]
        for part in LocalStoragePart.allCases {
            let bytes=try data("journal/"+part.rawValue+".json")
            try wrNeed(bytes==expectedParts[part],.hash);parts[part]=bytes
        }
        guard let project=UUID(uuidString:context.project),let account=UUID(uuidString:context.account) else {throw WindowsReaderError.binding}
        let projection=try ReceiveProductProjection(parts:parts,local:local,project:project,account:account)
        let projectionHash=byteHash(try canonical(LocalStoragePart.allCases.map{DigestEntry(path:$0.rawValue,bytes:parts[$0]!.count,sha256:byteHash(parts[$0]!))}.sorted{$0.path<$1.path}))
        let planHash=byteHash(try canonical(["context":context.digest,"projection":projectionHash,"journal":byteHash(canonical(ledger))]))
        let complete=try canonical(["format":"dedicated-product-store-offline-v1","plan":planHash,"context":context.digest,"projection":projectionHash,"local":context.localProjectID])
        try wrNeed(data("complete.json")==complete && data("identity.json")==complete && data("state")==Data("preparing\n".utf8),.hash)
        let required=Set(["operation.lock","identity.json","complete.json","state","sync.sqlite","metadata/store.sqlite","journal/context.json"])
            .union(LocalStoragePart.allCases.map{"journal/"+$0.rawValue+".json"})
            .union(projection.documents.map{"texts/"+$0.localPath})
        let optional:Set<String>=["metadata/store.sqlite-wal","metadata/store.sqlite-shm","sync.sqlite-wal","sync.sqlite-shm"]
        try wrNeed(required.isSubset(of:inventory.files) && inventory.files.isSubset(of:required.union(optional)),.shape)
        try wrNeed(inventory.directories==["metadata","journal","texts","texts/"+projection.root.name],.shape)
        for document in projection.documents {try wrNeed(data("texts/"+document.localPath)==document.body,.body)}
        for wal in ["sync.sqlite-wal","metadata/store.sqlite-wal"] {if let bytes=files[wal] {try wrNeed(bytes.isEmpty,.file)}}
        try ReceiveProductSQL(url:root.appendingPathComponent("sync.sqlite"),create:false,immutable:true,check:check).verify(projection)
        try ReceiveProductMetadata.verifyImmutable(projection,url:root.appendingPathComponent("metadata/store.sqlite"),check:check)
        // Reject changes during reading, including replacements and new files; never repair them.
        let after=try SafeFiles.inventory(root)
        try wrNeed(after.files==inventory.files && after.directories==inventory.directories,.file)
        for (name,bytes) in files {try check();try wrNeed(SafeFiles.read(root.appendingPathComponent(name),limit:32*1024*1024)==bytes,.file)}
        let journalAfter=try SafeFiles.inventory(journal)
        try wrNeed(journalAfter.files==journalInventory.files && journalAfter.directories==journalInventory.directories && SafeFiles.read(journal.appendingPathComponent("run.json"),limit:64*1024*1024)==ledgerBytes,.file)
        try check()
        return .init(runID:context.runID,folderName:projection.root.name,documents:projection.order.children.map{id in
            let d=projection.documents.first{$0.id==id}!
            return .init(id:d.id,name:d.name,text:String(decoding:d.body,as:UTF8.self),byteCount:d.body.count)
        })
    }
}
