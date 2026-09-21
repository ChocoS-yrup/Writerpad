import Foundation

/// Comparison expectations only. Reviewed input requires a separate sealed offline execution context.
struct SyntheticABExpected {
    let reviewedTarget: ReviewedReceiveTarget?
    let account: String
    let project: String
    let values: [WindowsJSON]
    let plan: WindowsJSON
    let members: Set<String>
    let references: Set<String>
    let binding: String
    private init(account: String,project: String,values: [WindowsJSON],plan: WindowsJSON,members: Set<String>,references: Set<String>,reviewedTarget: ReviewedReceiveTarget? = nil) {
        self.reviewedTarget = reviewedTarget
        self.account = account; self.project = project; self.values = values; self.plan = plan
        self.members = members; self.references = references
        if let reviewedTarget {
            binding = byteHash(WindowsJSON.object(["handoff":.string(reviewedTarget.review.handoff_sha256),"target":.string(reviewedTarget.targetSHA256),"binding":reviewedTarget.binding]).encoded(lf:true))
        } else { binding = byteHash(WindowsJSON.array(values).encoded(lf:true)) }
    }
    static func reviewedComparison(_ target:ReviewedReceiveTarget) throws -> Self {
        try Self(account:target.binding.str("account_id"),project:target.binding.str("project_id"),values:[],plan:.null,members:[],references:[],reviewedTarget:target)
    }
    static func fixture(includeSpecial: Bool = false) -> Self {
        func id(_ n: Int) -> String { String(format:"ee260914-0000-4000-8000-%012d",9000+n) }
        let account = id(1), project = id(2), root = id(3), doc = id(4), empty = id(5), topOrder = id(6), rootOrder = id(7)
        let date: WindowsJSON = .string("2026-09-14T00:00:00.123456Z")
        func str(_ s: String) -> WindowsJSON { .string(s) }
        let folder: WindowsJSON = .object(["project_id":str(project),"folder_id":str(root),"parent_folder_id":.null,"name":str("합성 AB"),"revision":.number("1"),"updated_at":date,"is_deleted":.bool(false),"deleted_at":.null])
        func document(_ ident: String,_ name: String,_ content: String) -> WindowsJSON {
            .object(["project_id":str(project),"document_id":str(ident),"parent_folder_id":str(root),"relative_path":str("합성 AB/"+name),"name":str(name),"revision":.number("1"),"structure_revision":.number("1"),"updated_at":date,"is_deleted":.bool(false),"deleted_at":.null,"content":str(content)])
        }
        func order(_ ident: String,_ parent: WindowsJSON,_ children: [String]) -> WindowsJSON {
            .object(["project_id":str(project),"tree_order_id":str(ident),"parent_folder_id":parent,"children":.array(children.map(str)),"revision":.number("1"),"updated_at":date])
        }
        let text = "Swift 합성 e\u{301}🙂\n", raw = Data(text.utf8)
        var documents = [document(doc,"본문.txt",text),document(empty,"빈문서.txt","")]
        if includeSpecial { documents.append(.object(["project_id":str(project),"document_id":str(id(8)),"relative_path":str("__antigravity__/synthetic-metadata"),"content":.null])) }
        let values: [WindowsJSON] = [.object(["id":str(account)]),
            .object(["supported":.bool(true),"project_id":str(project),"project_sync_mode":str("ID_BASED"),"migration_epoch":.number("1"),"contract_version":str("0.2.0"),"canonical_contract_sha256":str(WindowsHandoffReader.contractSHA),"server_contract_sha256":str(WindowsHandoffReader.contractSHA),"server_protocol_version":.number("3"),"supported_protocol_versions":.array([.number("3")]),"server_capabilities":.array(WindowsHandoffReader.serverCaps.sorted().map(str))]),
            .array([.object(["project_id":str(project),"owner_id":str(account),"trashed_at":.null,"trashed_by":.null])]),
            .array([.object(["project_id":str(project),"project_sync_mode":str("ID_BASED"),"migration_epoch":.number("1")])]),
            .array(documents),.array([folder]),.array([order(topOrder,.null,[root]),order(rootOrder,str(root),[doc,empty])])]
        let plan: WindowsJSON = .object(["root_id":str(root),"parent_id":.null,"body_id":str(doc),"empty_id":str(empty),"parent_order_id":str(topOrder),"root_order_id":str(rootOrder),"root_path":str("합성 AB"),"body_name":str("본문.txt"),"empty_name":str("빈문서.txt"),"initial_body":.object(["sha256":str(byteHash(raw)),"utf8_bytes":.number(String(raw.count)),"ends_lf":.bool(true)])])
        return Self(account:account,project:project,values:values,plan:plan,members:[root,doc,empty,rootOrder],references:[topOrder])
    }
    func responses() -> [SyntheticABResponse] {
        values.enumerated().map { i,v in
            let count: Int? = { if case let .array(a) = v, i >= 2 { return a.count }; return nil }()
            return SyntheticABResponse(raw:v.encoded(lf:true),contentRange:count.map { $0 == 0 ? "*/0" : "0-\($0-1)/\($0)" })
        }
    }
    func validateResponse(_ index: Int,_ response: SyntheticABResponse) throws -> WindowsJSON {
        guard (0..<7).contains(index) else { throw SyntheticABError.contract }
        try abNeed((index < 2 ? [200] : [200,206]).contains(response.status),.httpStatus)
        do {
            let v = try WindowsJSON.decode(response.raw)
            if index == 0 { try abNeed(v.str("id") == account,.subject) }
            else if index == 1 {
                // Same object wire shape as Python A/B. Retained singleton adaptation is separate.
                try abNeed(v.get("supported") == .bool(true) && v.str("project_id") == project && v.str("project_sync_mode") == "ID_BASED" && v.get("migration_epoch").int(1) == 1 && v.str("contract_version") == "0.2.0" && v.str("canonical_contract_sha256") == WindowsHandoffReader.contractSHA && v.str("server_contract_sha256") == WindowsHandoffReader.contractSHA,.handshake)
                let version = try v.get("server_protocol_version").int(3), supported = try v.list("supported_protocol_versions").map { try $0.int(1) }
                try abNeed(Set(supported).count == supported.count && supported.contains(3) && supported.contains(version),.handshake)
                try WindowsHandoffReader.capabilities(v.get("server_capabilities"),WindowsHandoffReader.serverCaps)
            } else {
                let list = try v.array(); try Self.count(response.contentRange,rows:list.count)
                for row in list { try abNeed(row.str("project_id") == project,.project) }
                if index == 2 {
                    try abNeed(list.count == 1,.project); let row = list[0]
                    try abNeed(row.str("owner_id") == account && row.get("trashed_at") == .null && row.get("trashed_by") == .null,.project)
                    if let deleted = try row.object()["is_deleted"] { try abNeed(deleted == .bool(false),.project) }
                } else if index == 3 {
                    try abNeed(list.count == 1 && list[0].str("project_sync_mode") == "ID_BASED" && list[0].get("migration_epoch").int(1) == 1,.settings)
                } else {
                    for row in list { try WindowsHandoffReader.row(row,kind:["document","folder","tree_order"][index-4],project:project) }
                }
            }
            return v
        } catch let error as SyntheticABError { throw error }
        catch { throw SyntheticABError.contract }
    }
    static func count(_ header: String?,rows: Int) throws {
        try abNeed(rows <= 10000,.count)
        try abNeed(rows == 0 ? ["*/0","0-0/0"].contains(header ?? "") : header == "0-\(rows-1)/\(rows)",.count)
    }
    func validatePass(_ values: [WindowsJSON]) throws -> Data {
        try abNeed(values.count == 7,.partialPass)
        do {
            if let reviewedTarget {
                _ = try reviewedTarget.compare(["documents":values[4].array(),"folders":values[5].array(),"tree_orders":values[6].array()])
            } else {
            var rows: [String:WindowsJSON] = [:], kinds: [String:String] = [:], special = Set<String>()
            for (i,kind) in ["document","folder","tree_order"].enumerated() {
                let key = WindowsHandoffReader.kinds[kind]!.1
                for r in try values[i+4].array() {
                    let id = try r.str(key); try abNeed(rows[id] == nil,.graph)
                    rows[id] = r; kinds[id] = kind
                    if kind == "document", try r.str("relative_path").hasPrefix("__antigravity__/") { special.insert(id) }
                }
                for wanted in try self.values[i+4].array() {
                    let id = try wanted.str(key)
                    if members.contains(id) || references.contains(id) { try abNeed(rows[id]?.equalBytes(wanted) == true,.targetChanged) }
                }
            }
            try WindowsHandoffReader.graph(rows:rows,kinds:kinds,special:special,roles:["members":members,"references":references,"context_only":special],plan:plan)
            }
            // Set/row order alone is insignificant; all other values remain in comparison bytes.
            var hs = try values[1].object()
            hs["server_capabilities"] = .array(try WindowsHandoffReader.strings(values[1].get("server_capabilities")).sorted().map { .string($0) })
            hs["supported_protocol_versions"] = .array(try values[1].list("supported_protocol_versions").sorted { try $0.int() < $1.int() })
            let keys = ["project_id","project_id","document_id","folder_id","tree_order_id"]
            var tables: [String:WindowsJSON] = [:]
            for i in 0..<5 { tables[WindowsHandoffReader.tables[i]] = .array(try values[i+2].array().sorted { try $0.str(keys[i]) < $1.str(keys[i]) }) }
            return WindowsJSON.object(["handshake":.object(hs),"tables":.object(tables)]).encoded(lf:true)
        } catch let error as SyntheticABError { throw error }
        catch { throw SyntheticABError.graph }
    }
}
