import Foundation
import SwiftData
import SQLite3
import Darwin

// Narrow dedicated writer, using the unchanged product schema, not the product AppEnvironment.
final class ReceiveProductSQL {
    private var db:OpaquePointer?
    let check:() throws -> Void
    init(url:URL,create:Bool,immutable:Bool=false,check:@escaping () throws -> Void) throws {
        self.check=check;try check();try SafeFiles.checked(url)
        if create {
            let fd=open(url.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0o600)
            guard fd>=0 else{throw ReceiveError.path};close(fd)
        } else {guard try SafeFiles.attributes(url) != nil else{throw ReceiveError.path}}
        try require(!immutable || !create,.path)
        var filename=url.path
        if immutable {
            for suffix in ["-wal","-journal"] {
                let sidecar=URL(fileURLWithPath:url.path+suffix)
                if try SafeFiles.attributes(sidecar) != nil {try require(SafeFiles.read(sidecar,limit:0).isEmpty,.corrupt)}
            }
            var components=URLComponents(url:url,resolvingAgainstBaseURL:false)!
            components.queryItems=[.init(name:"mode",value:"ro"),.init(name:"immutable",value:"1")]
            filename=components.url!.absoluteString
        }
        var flags=create ? SQLITE_OPEN_READWRITE:SQLITE_OPEN_READONLY
        if immutable {flags |= SQLITE_OPEN_URI | SQLITE_OPEN_NOFOLLOW}
        #if os(iOS)
        flags |= SQLITE_OPEN_FILEPROTECTION_COMPLETE
        #endif
        guard sqlite3_open_v2(filename,&db,flags|SQLITE_OPEN_NOMUTEX,nil)==SQLITE_OK else{if let db{sqlite3_close(db)};db=nil;throw ReceiveError.io}
        sqlite3_busy_timeout(db,0)
    }
    deinit {if let db{sqlite3_close(db)}}
    func exec(_ sql:String) throws {try check();guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else{throw ReceiveError.io};try check()}
    func rows(_ sql:String,_ parameters:[String?]=[]) throws -> [[String?]] {
        try check();var stmt:OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK else{throw ReceiveError.io};defer{sqlite3_finalize(stmt)}
        for (i,p) in parameters.enumerated() {
            let code:Int32
            if let p {code=p.withCString{sqlite3_bind_text(stmt,Int32(i+1),$0,Int32(p.utf8.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self))}}
            else{code=sqlite3_bind_null(stmt,Int32(i+1))}
            guard code==SQLITE_OK else{throw ReceiveError.io}
        }
        var result:[[String?]]=[]
        while true {
            try check();let code=sqlite3_step(stmt)
            if code==SQLITE_DONE{break};guard code==SQLITE_ROW else{throw ReceiveError.io}
            result.append((0..<sqlite3_column_count(stmt)).map { i in
                guard sqlite3_column_type(stmt,i) != SQLITE_NULL,let p=sqlite3_column_text(stmt,i) else{return nil}
                return String(decoding:UnsafeBufferPointer(start:p,count:Int(sqlite3_column_bytes(stmt,i))),as:UTF8.self)
            })
        };try check();return result
    }
    static func migration(_ n:Int) throws -> Data {
        #if SWIFT_PACKAGE
        let bundle=Bundle.module
        #else
        let bundle=Bundle.main
        #endif
        guard let u=bundle.url(forResource:"SyncV2StoreSchemaV\(n)",withExtension:"sql") else{throw ReceiveError.io}
        return try Data(contentsOf:u)
    }
    func migrate() throws {
        for n in 1...16 {
            let bytes=try Self.migration(n),text=String(decoding:bytes,as:UTF8.self),marker="'design-fixture-v\(n)'"
            guard text.contains(marker) else{throw ReceiveError.io}
            try exec(text.replacingOccurrences(of:marker,with:"'"+byteHash(bytes)+"'"));sqlite3_busy_timeout(db,0)
        }
        try exec("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;")
    }
    func insert(_ table:String,_ columns:[String],_ values:[String?]) throws {
        // Identifiers are static call-site constants; every imported value is a bound parameter.
        _ = try rows("INSERT INTO "+table+" ("+columns.joined(separator:",")+") VALUES ("+Array(repeating:"?",count:values.count).joined(separator:",")+")",values)
    }
    func write(_ p:ReceiveProductProjection) throws {
        func u(_ x:UUID)->String{x.uuidString.lowercased()}
        try exec("BEGIN IMMEDIATE")
        try insert("sync_projects",["local_project_id","server_project_id","binding_kind","project_name","owner_subject","created_at","updated_at"],
                   [u(p.local),u(p.project),"existing_server_project",p.root.name,u(p.account),p.root.updated,p.root.updated])
        for d in p.documents {
            try insert("sync_documents",["document_id","local_project_id","project_id","local_path","server_path","server_revision","base_content","base_hash","is_deleted","server_updated_at","sync_state","created_at","updated_at","parent_folder_id","name","structure_revision"],
                       [u(d.id),u(p.local),u(p.project),d.localPath,d.remotePath,String(d.revision),String(data:d.body,encoding:.utf8)!,d.hash,"0",d.updated,"synced",d.updated,d.updated,u(d.parent),d.name,String(d.structureRevision)])
        }
        let f=p.root
        try insert("sync_folders",["folder_id","local_project_id","project_id","parent_folder_id","name","server_revision","is_deleted","server_updated_at","sync_state","created_at","updated_at"],
                   [u(f.id),u(p.local),u(p.project),f.remoteParent.map(u),f.name,String(f.revision),"0",f.updated,"synced",f.updated,f.updated])
        let o=p.order,children=String(decoding:try JSONSerialization.data(withJSONObject:o.children.map(u)),as:UTF8.self)
        try insert("sync_tree_orders",["tree_order_id","local_project_id","project_id","parent_folder_id","children_json","server_revision","server_updated_at","sync_state","created_at","updated_at"],
                   [u(o.id),u(p.local),u(p.project),u(o.parent),children,String(o.revision),o.updated,"synced",o.updated,o.updated])
        try exec("COMMIT")
    }
    func verify(_ p:ReceiveProductProjection) throws {
        func u(_ x:UUID)->String{x.uuidString.lowercased()}
        try wrNeed(rows("PRAGMA user_version")==[["16"]] && rows("PRAGMA integrity_check")==[["ok"]] && rows("PRAGMA foreign_key_check").isEmpty,.shape)
        for n in 1...16 {try wrNeed(rows("SELECT name,checksum FROM schema_migrations WHERE version=?",[String(n)])==[["SyncV2StoreSchemaV\(n)",byteHash(Self.migration(n))]],.shape)}
        try wrNeed(rows("SELECT local_project_id,server_project_id,owner_subject,binding_kind,project_name FROM sync_projects")==[[u(p.local),u(p.project),u(p.account),"existing_server_project",p.root.name]],.binding)
        let actual=try rows("SELECT document_id,local_path,server_path,server_revision,base_content,base_hash,is_deleted,server_updated_at,sync_state,parent_folder_id,name,structure_revision,local_project_id,project_id FROM sync_documents ORDER BY document_id")
        let expected:[[String?]]=p.documents.map{[u($0.id),$0.localPath,$0.remotePath,String($0.revision),String(data:$0.body,encoding:.utf8)!,$0.hash,"0",$0.updated,"synced",u($0.parent),$0.name,String($0.structureRevision),u(p.local),u(p.project)]}
        try wrNeed(actual==expected,.body)
        let f=p.root
        try wrNeed(rows("SELECT folder_id,parent_folder_id,name,server_revision,is_deleted,server_updated_at,sync_state,local_project_id,project_id FROM sync_folders")==[[u(f.id),f.remoteParent.map(u),f.name,String(f.revision),"0",f.updated,"synced",u(p.local),u(p.project)]],.shape)
        let o=p.order,children=String(decoding:try JSONSerialization.data(withJSONObject:o.children.map(u)),as:UTF8.self)
        try wrNeed(rows("SELECT tree_order_id,parent_folder_id,children_json,server_revision,server_updated_at,sync_state,local_project_id,project_id FROM sync_tree_orders")==[[u(o.id),u(o.parent),children,String(o.revision),o.updated,"synced",u(p.local),u(p.project)]],.shape)
        let allowed:Set<String>=["schema_migrations","sync_projects","sync_documents","sync_folders","sync_tree_orders","sqlite_sequence"]
        for row in try rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'") {
            let table=row[0]!
            if !allowed.contains(table) {try wrNeed(rows("SELECT count(*) FROM \""+table.replacingOccurrences(of:"\"",with:"\"\"")+"\"")==[["0"]],.shape)}
        }
    }
}

enum ReceiveProductMetadata {
    static func withContext<T>(url:URL,write:Bool,_ body:(ModelContext)throws->T) throws -> T {
        try autoreleasepool {
            let schema=Schema(WriterPadSchemaV1.models)
            let config=ModelConfiguration("DedicatedReceive",schema:schema,url:url,allowsSave:write,cloudKitDatabase:.none)
            let container=try ModelContainer(for:schema,migrationPlan:WriterPadMigrationPlan.self,configurations:[config])
            let context=ModelContext(container);context.autosaveEnabled=false
            return try body(context)
        }
    }
    static func write(_ p:ReceiveProductProjection,url:URL,check:()throws->Void,prepareFiles:()throws->Void={}) throws {
        try check()
        try withContext(url:url,write:true) {c in
            try prepareFiles();try check()
            try wrNeed(c.fetchCount(FetchDescriptor<ProjectRecord>())==0 && c.fetchCount(FetchDescriptor<DocumentRecord>())==0,.shape)
            let date=try ReceiveProductProjection.date(p.root.updated)
            c.insert(ProjectRecord(id:p.local,name:p.root.name,createdAt:date,modifiedAt:date))
            func put(id:UUID,parent:UUID?,path:String,kind:String,order:Int,updated:String,hash:String?) throws {
                c.insert(DocumentRecord(id:id,projectID:p.local,kindRawValue:kind,parentID:parent,relativePath:path,userOrder:order,modifiedAt:try ReceiveProductProjection.date(updated),contentHash:hash,isDeleted:false,originalPath:nil,deletedAt:nil,cursorLocation:0,selectionLength:0,isExpanded:false))
            }
            try put(id:p.root.id,parent:nil,path:p.root.name,kind:"folder",order:0,updated:p.root.updated,hash:nil)
            for d in p.documents {try check();try put(id:d.id,parent:d.parent,path:d.localPath,kind:"text",order:p.order.children.firstIndex(of:d.id)!,updated:d.updated,hash:d.hash)}
            try check();try c.save();try check()
        }
    }
    static func verify(_ p:ReceiveProductProjection,url:URL,check:()throws->Void) throws {
        try check();try withContext(url:url,write:false) {c in
            let projects=try c.fetch(FetchDescriptor<ProjectRecord>()),docs=try c.fetch(FetchDescriptor<DocumentRecord>())
            try wrNeed(projects.count==1 && projects[0].id==p.local && projects[0].name==p.root.name && projects[0].modifiedAt==ReceiveProductProjection.date(p.root.updated) && projects[0].createdAt==ReceiveProductProjection.date(p.root.updated),.binding)
            try wrNeed(docs.count==3,.shape)
            for d in docs {
                try check();try wrNeed(d.projectID==p.local && !d.isTrashed && d.deletedAt==nil && d.originalPath==nil && d.cursorLocation==0 && d.selectionLength==0 && !d.isExpanded,.shape)
                if d.id==p.root.id {try wrNeed(d.parentID==nil && d.relativePath==p.root.name && d.kindRawValue=="folder" && d.contentHash==nil && d.userOrder==0 && d.modifiedAt==ReceiveProductProjection.date(p.root.updated),.shape)}
                else {
                    guard let v=p.documents.first(where:{$0.id==d.id}) else{throw WindowsReaderError.shape}
                    try wrNeed(d.parentID==v.parent && d.relativePath==v.localPath && d.kindRawValue=="text" && d.contentHash==v.hash && d.userOrder==p.order.children.firstIndex(of:v.id)! && d.modifiedAt==ReceiveProductProjection.date(v.updated),.body)
                }
            }
            try wrNeed(c.fetchCount(FetchDescriptor<BootstrapRecord>())==0 && c.fetchCount(FetchDescriptor<WorkspaceRecord>())==0 && c.fetchCount(FetchDescriptor<AppStateRecord>())==0,.shape)
        };try check()
    }
}

// Fixed current SwiftData schema, queried without ModelContainer or sidecar writes.
// Unknown schema/values fail closed; this reader never migrates a database.
extension ReceiveProductMetadata {
    static func verifyImmutable(_ p:ReceiveProductProjection,url:URL,check:@escaping ()throws->Void) throws {
        let db=try ReceiveProductSQL(url:url,create:false,immutable:true,check:check)
        try wrNeed(db.rows("PRAGMA integrity_check")==[["ok"]],.shape)
        func hex(_ id:UUID)->String {id.uuidString.replacingOccurrences(of:"-",with:"")}
        let projects=try db.rows("SELECT hex(ZID),ZNAME,ZCREATEDAT,ZMODIFIEDAT FROM ZPROJECTRECORD")
        try wrNeed(projects.count==1 && projects[0][0]==hex(p.local) && projects[0][1]==p.root.name,.binding)
        func date(_ raw:String?,_ expected:String)throws {
            guard let raw,let value=Double(raw) else {throw WindowsReaderError.shape}
            try wrNeed(abs(value - ReceiveProductProjection.date(expected).timeIntervalSinceReferenceDate)<0.00001,.shape)
        }
        try date(projects[0][2],p.root.updated);try date(projects[0][3],p.root.updated)
        let docs=try db.rows("SELECT hex(ZID),hex(ZPROJECTID),hex(ZPARENTID),ZKINDRAWVALUE,ZRELATIVEPATH,ZCONTENTHASH,ZUSERORDER,ZMODIFIEDAT,ZISTRASHED,ZDELETEDAT,ZORIGINALPATH,ZCURSORLOCATION,ZSELECTIONLENGTH,ZISEXPANDED FROM ZDOCUMENTRECORD")
        try wrNeed(docs.count==3 && Set(docs.compactMap{$0[0]}).count==3,.shape)
        for row in docs {
            try check()
            try wrNeed(row[1]==hex(p.local) && row[8]=="0" && row[9]==nil && row[10]==nil && row[11]=="0" && row[12]=="0" && row[13]=="0",.shape)
            if row[0]==hex(p.root.id) {
                try wrNeed(row[2]=="" && row[3]=="folder" && row[4]==p.root.name && row[5]==nil && row[6]=="0",.shape)
                try date(row[7],p.root.updated)
            } else {
                guard let d=p.documents.first(where:{hex($0.id)==row[0]}),let index=p.order.children.firstIndex(of:d.id) else {throw WindowsReaderError.shape}
                try wrNeed(row[2]==hex(d.parent) && row[3]=="text" && row[4]==d.localPath && row[5]==d.hash && row[6]==String(index),.body)
                try date(row[7],d.updated)
            }
        }
        for table in ["ZBOOTSTRAPRECORD","ZWORKSPACERECORD","ZAPPSTATERECORD"] {
            try wrNeed(db.rows("SELECT count(*) FROM "+table)==[["0"]],.shape)
        }
    }
}
