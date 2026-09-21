import Foundation

public struct WindowsHandoffExpectation: Sendable {
    public let handoffSHA256: String
    let binding: WindowsJSON
    public init(handoffSHA256: String, bindingJSON: Data) throws {
        try wrNeed(handoffSHA256.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil,.pin)
        let binding = try WindowsJSON.decode(bindingJSON)
        try binding.keys(["endpoint","account_id","project_id","project_sync_mode","migration_epoch","contract_version","contract_sha256"])
        self.handoffSHA256 = handoffSHA256; self.binding = binding
    }
    /// Pin to the already supplied retained record; never a current server approval/profile.
    public static func retainedSeptember14() throws -> Self {
        try Self(handoffSHA256:"4a108a187de380a4692f24ebcfb6c3f07f1de877e4958fbd47cc5ee6dca12722",bindingJSON:Data(#"{"endpoint":"https://mhpnszcorfzrvhyondxr.supabase.co","account_id":"e487c6ea-1c2b-4a90-821e-91e8547106de","project_id":"d8f50b5f-ae0e-42f8-9296-5d5885a5b304","project_sync_mode":"ID_BASED","migration_epoch":1,"contract_version":"0.2.0","contract_sha256":"416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670"}"#.utf8))
    }
}

public struct WindowsHandoffReview: Encodable, Equatable, Sendable {
    public let handoff_sha256: String
    public let source_files: Int
    public let members: Int
    public let references: Int
    public let context_only: Int
    public let normal_bodies_checked: Int
    public let missing_evidence: Int
    public let raw_array_counts: [String:Int]
    public let retained_links_checked = true
    public let retained_row_contract_checked = true
    public let baseline_ready = false
    public let baseline_applied = false
    public let execution_allowed = false
    public let app_binding_created = false
    public let editing_allowed = false
    public let sending_allowed = false
    public let automatic_receive_allowed = false
    public let atomic_snapshot = false
    public let current_server_verified = false
    public let fresh_ab_verified = false
    public let special_body_semantics_verified = false
    public let full_windows_engine_equivalence_verified = false
    public let schema_finalized = false
    public func requireApplyInput() throws { throw WindowsReaderError.unverified }
}

/// Native, memory-only inspection. There is intentionally no SyntheticInput/store conversion.
public enum WindowsHandoffReader {
    static let flags = ["baseline_ready","baseline_applied","execution_allowed","app_binding_created","complete","atomic_snapshot","editing_allowed","sending_allowed","automatic_receive_allowed"]
    static let contractSHA = "416c1b99edb9bda694731dee4b25688d9d82d1f32610aa23ddfda571ec3c7670"
    static let tables = ["projects","project_sync_settings","documents","folders","tree_orders"]
    static let kinds = ["document":("documents","document_id","Q14.body"),"folder":("folders","folder_id","Q15.body"),"tree_order":("tree_orders","tree_order_id","Q16.body")]
    static let serverCaps: Set<String> = ["atomic_structure_commit","contract_allowlist_validation","project_mode_migration_lock","folder_tombstones","id_tree_validation","legacy_epoch_zero_adapter","storage_name_v1","document_commit_v1"]
    static let clientCaps: Set<String> = ["folders_authoritative","tree_order_ids","tombstones","immutable_batch_contract_metadata","operation_attempt_history","operation_state_events","storage_name_v1","document_commit_v1"]
    static func uuid(_ s: String) throws { try wrNeed(UUID(uuidString:s)?.uuidString.lowercased() == s,.binding) }
    static func path(_ p: String) throws {
        try wrNeed(!p.isEmpty && !p.contains("\\") && !p.contains(":") && !p.unicodeScalars.contains { $0.value < 32 || $0.value == 127 },.reference)
        try wrNeed(p.components(separatedBy:"/").allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." },.reference)
    }
    static func authority(_ v: WindowsJSON) throws { try v.keys(flags); try wrNeed(v.object().values.allSatisfy { $0 == .bool(false) },.authority) }
    static func strings(_ v: WindowsJSON) throws -> [String] { try v.array().map { try $0.string() } }
    static func capabilities(_ v: WindowsJSON,_ required: Set<String>) throws {
        let list = try strings(v); try wrNeed(Set(list).count == list.count && required.isSubset(of:Set(list)),.contract)
    }
    static func body(_ v: WindowsJSON) throws -> WindowsJSON {
        let s = try v.string(); try wrNeed(!s.contains("\r") && !s.contains("\0"),.body)
        let data = Data(s.utf8)
        return .object(["sha256":.string(byteHash(data)),"utf8_bytes":.number(String(data.count)),"ends_lf":.bool(data.last == 10)])
    }
    static func date(_ v: WindowsJSON) throws {
        let s = try v.string(), pattern = #"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,6}))?(Z|[+-][0-9]{2}:[0-9]{2})$"#
        let re = try NSRegularExpression(pattern:pattern)
        guard let m = re.firstMatch(in:s,range:NSRange(s.startIndex...,in:s)), m.range == NSRange(s.startIndex...,in:s) else { throw WindowsReaderError.contract }
        func field(_ n: Int) -> String { Range(m.range(at:n),in:s).map { String(s[$0]) } ?? "" }
        let numbers = (1...6).map { Int(field($0))! }
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(secondsFromGMT:0)!
        let dc = DateComponents(year:numbers[0],month:numbers[1],day:numbers[2],hour:numbers[3],minute:numbers[4],second:numbers[5])
        guard numbers[0] >= 1, let date = calendar.date(from:dc) else { throw WindowsReaderError.contract }
        let round = calendar.dateComponents([.year,.month,.day,.hour,.minute,.second],from:date)
        try wrNeed(round == dc,.contract)
        let zone = field(8)
        if zone != "Z" {
            let parts = zone.dropFirst().split(separator:":"); let h = Int(parts[0])!, m = Int(parts[1])!
            try wrNeed(h <= 14 && m <= 59 && (h != 14 || m == 0),.contract)
        }
    }
    static func row(_ r: WindowsJSON,kind: String,project: String) throws {
        guard let (_,key,_) = kinds[kind] else { throw WindowsReaderError.shape }
        try wrNeed(r.str("project_id") == project,.binding); try uuid(r.str(key))
        if kind == "document" {
            try path(r.str("relative_path"))
            if try r.str("relative_path").hasPrefix("__antigravity__/") { return }
        }
        _ = try r.get("revision").int(1); try date(r.get("updated_at"))
        if try r.get("parent_folder_id") != .null { try uuid(r.str("parent_folder_id")) }
        if kind == "tree_order" {
            let children = try strings(r.get("children")); for id in children { try uuid(id) }
            try wrNeed(Set(children).count == children.count,.structure); return
        }
        let name = try r.str("name"); try path(name); try wrNeed(!name.contains("/"),.structure)
        if try r.get("is_deleted") == .bool(true) { try date(r.get("deleted_at")) }
        else { try wrNeed(r.get("is_deleted") == .bool(false) && r.get("deleted_at") == .null,.contract) }
        if kind == "document" {
            _ = try r.get("structure_revision").int(1); let meta = try body(r.get("content"))
            let o = try r.object()
            if let hash = o["content_sha256"] { try wrNeed(hash == meta.get("sha256"),.body) }
            if let count = o["content_byte_count"] { try wrNeed(count.int() == meta.get("utf8_bytes").int(),.body) }
        }
    }
    public static func files(from portable: Data) throws -> [String:Data] {
        let envelope = try WindowsJSON.decode(portable,limit:48*1024*1024)
        try envelope.keys(["format","files"])
        try wrNeed(envelope.str("format") == "ipad-windows-handoff-review-bytes-v1",.shape)
        let encoded = try envelope.get("files").object(); try wrNeed(encoded.count <= 128,.size)
        var files: [String:Data] = [:], total = 0
        for (p,value) in encoded {
            try path(p)
            let s = try value.string(); guard let raw = Data(base64Encoded:s), raw.base64EncodedString() == s else { throw WindowsReaderError.shape }
            total += raw.count; try wrNeed(raw.count <= 4*1024*1024 && total <= 32*1024*1024,.size)
            files[p] = raw
        }
        return files
    }
    public static func review(portable: Data, expected: WindowsHandoffExpectation, checkpoint: () throws -> Void = {}) throws -> WindowsHandoffReview {
        try checkpoint(); let data = try files(from:portable); try checkpoint()
        return try review(files:data,expected:expected,checkpoint:checkpoint)
    }
    public static func review(files: [String:Data], expected: WindowsHandoffExpectation, checkpoint: () throws -> Void = {}) throws -> WindowsHandoffReview {
        try checkpoint()
        try wrNeed(files.count <= 128 && files.values.allSatisfy { $0.count <= 4*1024*1024 } && files.values.reduce(0,{$0+$1.count}) <= 32*1024*1024,.size)
        for p in files.keys { try path(p) }
        guard let original = files["handoff.json"], byteHash(original) == expected.handoffSHA256 else { throw WindowsReaderError.pin }
        let h = try WindowsJSON.decode(original), b = expected.binding
        try h.keys(["format","intended_format","schema_version","schema_finalized","blocked_reasons","source_run_id","candidate_sha256","binding","plan_contract_sha256","plan_artifact_ref","target","artifacts","creation","observations","evidence","missing_evidence","checks","authority","local_source_links_verified","raw_count_independently_verified","server_provenance_verified"])
        try wrNeed(h.str("format") == "windows-isolated-receive-handoff-draft-v1" && h.str("intended_format") == "windows-isolated-receive-handoff-v1" && h.get("schema_version").int(1) == 1 && h.get("schema_finalized") == .bool(false),.shape)
        try authority(h.get("authority")); try wrNeed(h.get("binding").equalBytes(b),.binding)
        let project = try b.str("project_id"), account = try b.str("account_id"), run = try h.str("source_run_id")
        try uuid(project); try uuid(account); try uuid(run)
        try wrNeed(b.str("project_sync_mode") == "ID_BASED" && b.get("migration_epoch").int(1) == 1 && b.str("contract_version") == "0.2.0" && b.str("contract_sha256") == contractSHA,.contract)
        var values: [String:WindowsJSON] = [:], raws: [String:Data] = [:], declared = Set(["handoff.json","completed.json"])
        for a in try h.list("artifacts") {
            try checkpoint(); try a.keys(["artifact_id","role","path","sha256","byte_count"])
            let aid = try a.str("artifact_id"), p = try a.str("path"); try path(aid)
            try wrNeed(!aid.contains("/") && raws[aid] == nil,.reference)
            try wrNeed(p == (aid == "target.json" ? aid : "source/"+aid) && a.str("role") == (aid == "target.json" ? "target-draft" : "retained-source"),.reference)
            guard let data = files[p] else { throw WindowsReaderError.reference }
            try wrNeed(data.count == a.get("byte_count").int() && byteHash(data) == a.str("sha256"),.hash)
            raws[aid] = data; values[aid] = try WindowsJSON.decode(data); declared.insert(p)
        }
        try wrNeed(Set(files.keys) == declared,.reference)
        func value(_ aid: String) throws -> WindowsJSON { guard let v = values[aid] else { throw WindowsReaderError.reference }; return v }
        func raw(_ aid: String) throws -> Data { guard let v = raws[aid] else { throw WindowsReaderError.reference }; return v }
        func resolve(_ ref: WindowsJSON) throws -> WindowsJSON {
            try ref.keys(["artifact_id","json_pointer"]); return try value(ref.str("artifact_id")).pointer(ref.str("json_pointer"))
        }
        guard let sealData = files["completed.json"] else { throw WindowsReaderError.reference }
        let done = try WindowsJSON.decode(sealData)
        try done.keys(["format","handoff_sha256","target_sha256","source_run_id","source_files","execution_allowed"])
        try wrNeed(done.str("format") == "windows-handoff-local-seal-v1" && done.str("handoff_sha256") == expected.handoffSHA256 && done.str("source_run_id") == run && done.get("execution_allowed") == .bool(false) && done.str("target_sha256") == byteHash(raw("target.json")),.hash)
        let sourceHashes = raws.filter { $0.key != "target.json" }.mapValues { WindowsJSON.string(byteHash($0)) }
        try wrNeed(done.get("source_files").equalBytes(.object(sourceHashes)),.hash)
        let sealNames = values.keys.filter { $0.hasSuffix("-candidate-prepared.json") }, terminalNames = values.keys.filter { $0.hasSuffix("-terminal.json") }
        try wrNeed(sealNames.count == 1 && terminalNames.count == 1,.reference)
        let seal = try value(sealNames[0]), terminal = try value(terminalNames[0]), candidate = try value("baseline-candidate.json"), plan = try value("plan.json"), scope = try value("scope.json")
        try wrNeed(seal.get("files").equalBytes(.object(sourceHashes.filter { !sealNames.contains($0.key) && !terminalNames.contains($0.key) })) && seal.str("sha256") == h.str("candidate_sha256") && seal.str("sha256") == byteHash(raw("baseline-candidate.json")),.hash)
        for flag in ["baseline_ready","baseline_applied","complete","execution_allowed","resumable","write_outcome_uncertain"] { try wrNeed(terminal.get(flag) == .bool(false),.authority) }
        try wrNeed(terminal.str("status") == "candidate-prepared" && terminal.get("reason") == .null && terminal.get("http_reserved").int() == 16 && terminal.get("writes_reserved").int() == 4 && terminal.get("writes_acknowledged").int() == 4,.evidence)
        for flag in ["baseline_ready","baseline_applied","complete","execution_allowed","app_binding_created","atomic_snapshot"] { try wrNeed(candidate.get(flag) == .bool(false),.authority) }
        try wrNeed(candidate.str("run_id") == run && scope.str("run_id") == run && candidate.str("format") == "windows-isolated-receive-baseline-candidate-v1" && plan.str("format") == "windows-isolated-target-bootstrap-v1" && scope.str("format") == "windows-isolated-target-bootstrap-v1",.binding)
        let planHash = byteHash(plan.encoded(lf:true))
        try wrNeed(h.str("plan_contract_sha256") == planHash && candidate.str("plan_sha256") == planHash && scope.str("plan_sha256") == planHash && resolve(h.get("plan_artifact_ref")).equalBytes(plan),.hash)
        try wrNeed(scope.get("max_requests").int() == 16 && scope.get("max_writes").int() == 4 && scope.get("max_seconds").int() == 180 && scope.get("expires_at").int() - scope.get("not_before").int() == 180,.contract)
        for k in ["endpoint","account_id","project_id"] { try wrNeed(candidate.get(k).equalBytes(b.get(k)) && plan.get(k).equalBytes(b.get(k)),.binding) }
        for k in ["project_sync_mode","migration_epoch","contract_sha256"] { try wrNeed(candidate.get(k).equalBytes(b.get(k)),.binding) }
        try wrNeed(plan.get("initial_revisions") == .null && plan.get("execution_allowed") == .bool(false) && plan.get("baseline_applied") == .bool(false),.authority)
        for n in ["metadata","orders"] { try wrNeed(plan.get("reference_sha256").str(n) == byteHash(raw("reference-"+n+".json")),.hash) }
        let target = try h.get("target"), manifest = try value("target.json")
        try target.keys(["manifest_ref","binding","root_id","parent_id","members","references","context_only"])
        try manifest.keys(["format","binding","root_id","parent_id","members","references","context_only","authority"])
        try authority(manifest.get("authority")); try wrNeed(manifest.str("format") == "windows-isolated-target-link-draft-v1" && resolve(target.get("manifest_ref")).equalBytes(manifest),.reference)
        for key in ["binding","root_id","parent_id","members","references","context_only"] { try wrNeed(target.get(key).equalBytes(manifest.get(key)),.reference) }
        try wrNeed(target.get("binding").equalBytes(b) && target.get("root_id") == plan.get("root_id") && target.get("parent_id") == plan.get("parent_id"),.binding)
        var hs = try value("Q2.body")
        if case let .array(a) = hs { try wrNeed(a.count == 1,.contract); hs = a[0] }
        try wrNeed(value("Q1.body").str("id") == account && hs.get("supported") == .bool(true) && hs.str("project_id") == project && hs.str("project_sync_mode") == "ID_BASED" && hs.get("migration_epoch").int(1) == 1 && hs.str("contract_version") == "0.2.0" && hs.str("canonical_contract_sha256") == contractSHA && hs.str("server_contract_sha256") == contractSHA,.contract)
        let protocolVersion = try hs.get("server_protocol_version").int(3), versions = try hs.list("supported_protocol_versions").map { try $0.int(1) }
        try wrNeed(Set(versions).count == versions.count && versions.contains(3) && versions.contains(protocolVersion),.contract); try capabilities(hs.get("server_capabilities"),serverCaps)
        for (pn,sn) in [(3,4),(12,13)] {
            let p = try value("Q\(pn).body").array(), s = try value("Q\(sn).body").array()
            try wrNeed(p.count == 1 && s.count == 1,.contract)
            try wrNeed(p[0].str("project_id") == project && p[0].str("owner_id") == account && p[0].get("trashed_at") == .null && p[0].get("trashed_by") == .null,.contract)
            if let deleted = try p[0].object()["is_deleted"] { try wrNeed(deleted == .bool(false),.contract) }
            try wrNeed(s[0].str("project_id") == project && s[0].str("project_sync_mode") == "ID_BASED" && s[0].get("migration_epoch").int(1) == 1,.contract)
        }
        var rows: [String:WindowsJSON] = [:], rowKinds: [String:String] = [:], special = Set<String>(), bodies = 0
        for (kind,(_,key,aid)) in kinds {
            let list = try value(aid).array(); try wrNeed(list.count <= 10000,.size)
            for r in list {
                try checkpoint(); try row(r,kind:kind,project:project); let id = try r.str(key)
                try wrNeed(rows[id] == nil,.structure); rows[id] = r; rowKinds[id] = kind
                if kind == "document" { if try r.str("relative_path").hasPrefix("__antigravity__/") { special.insert(id) } else { bodies += 1 } }
            }
        }
        var seen = Set<String>(), roles: [String:Set<String>] = [:]
        for role in ["members","references","context_only"] {
            roles[role] = []
            for entry in try target.list(role) {
                try checkpoint(); let id = try entry.str("entity_id"), kind = try entry.str("entity_kind")
                guard let (_,_,aid) = kinds[kind], let r = rows[id], rowKinds[id] == kind else { throw WindowsReaderError.reference }
                try wrNeed(seen.insert(id).inserted,.reference); roles[role]!.insert(id)
                let refs = try entry.list("source_refs"); try wrNeed(refs.count == 1 && refs[0].str("artifact_id") == aid && resolve(refs[0]).equalBytes(r),.reference)
                try wrNeed(refs[0].str("json_pointer").range(of:"^/(0|[1-9][0-9]*)$",options:.regularExpression) != nil,.reference)
                if special.contains(id) {
                    try entry.keys(["entity_id","entity_kind","classification","source_refs"])
                    try wrNeed(role == "context_only" && entry.str("classification") == "special-metadata",.reference); continue
                }
                var keys = ["entity_id","entity_kind","parent_id","name","revision","allowed_actions","source_refs"]
                keys += kind == "tree_order" ? ["children"] : ["is_deleted"]
                if kind == "document" { keys += ["structure_revision","body"] }
                try entry.keys(keys)
                try wrNeed(entry.list("allowed_actions").isEmpty && entry.get("parent_id").equalBytes(r.get("parent_folder_id")) && entry.get("revision").int(1) == r.get("revision").int(1),.reference)
                try wrNeed(entry.get("name").equalBytes(kind == "tree_order" ? .null : r.get("name")),.reference)
                if kind == "tree_order" { try wrNeed(entry.get("children").equalBytes(r.get("children")),.structure) }
                else { try wrNeed(entry.get("is_deleted") == r.get("is_deleted"),.contract) }
                if kind == "document" { try wrNeed(entry.get("structure_revision").int(1) == r.get("structure_revision").int(1) && entry.get("body").equalBytes(body(r.get("content"))),.body) }
            }
        }
        try wrNeed(seen == Set(rows.keys),.reference)
        try graph(rows:rows,kinds:rowKinds,special:special,roles:roles,plan:plan)
        let wanted = WindowsJSON.object(["root":try lookup(rows,plan.str("root_id")),"documents":.array([try lookup(rows,plan.str("body_id")),try lookup(rows,plan.str("empty_id"))]),"orders":.array([try lookup(rows,plan.str("parent_order_id")),try lookup(rows,plan.str("root_order_id"))])])
        try wrNeed(candidate.get("candidate").equalBytes(wanted),.reference)
        try creation(h:h,values:values,rows:rows,plan:plan,binding:b,resolve:resolve)
        let evidence = try observations(h:h,values:values,raws:raws,binding:b,resolve:resolve)
        let checks = try h.list("checks"), checkIDs = try checks.map { try $0.str("check_id") }
        try wrNeed(checks.count == 8 && Set(checkIDs) == Set(["identity_project","handshake_contract","settings_coherence","target_binding","body_versions","visible_completeness","creation_link","preapply_consistency"]),.evidence)
        for check in checks {
            try wrNeed(check.get("reported").str("run_id") == run,.evidence)
            for r in try check.list("evidence_refs") { _ = try resolve(r) }
            // Incoming reported/independent verification claims cannot grant native authority.
        }
        try checkpoint()
        return WindowsHandoffReview(handoff_sha256:expected.handoffSHA256,source_files:sourceHashes.count,members:roles["members"]!.count,references:roles["references"]!.count,context_only:roles["context_only"]!.count,normal_bodies_checked:bodies,missing_evidence:evidence.1,raw_array_counts:evidence.0)
    }
    static func lookup(_ rows: [String:WindowsJSON],_ id: String) throws -> WindowsJSON { guard let r = rows[id] else { throw WindowsReaderError.reference }; return r }
    static func graph(rows: [String:WindowsJSON],kinds: [String:String],special: Set<String>,roles: [String:Set<String>],plan: WindowsJSON) throws {
        let nodes = rows.filter { kinds[$0.key] != "tree_order" && !special.contains($0.key) }, folders = Set(kinds.filter { $0.value == "folder" }.keys)
        var paths = Set<String>(), orders: [String:WindowsJSON] = [:]
        func parent(_ r: WindowsJSON) throws -> String { let p = try r.get("parent_folder_id"); return p == .null ? "" : try p.string() }
        for (id,r) in nodes {
            var names = [try r.str("name")], seen: Set<String> = [id], p = try parent(r)
            while !p.isEmpty {
                try wrNeed(folders.contains(p) && seen.insert(p).inserted,.structure)
                let ancestor = try lookup(rows,p); names.insert(try ancestor.str("name"),at:0)
                try wrNeed(r.get("is_deleted") == .bool(true) || ancestor.get("is_deleted") == .bool(false),.structure)
                p = try parent(ancestor)
            }
            let path = names.joined(separator:"/")
            // Conservative host Unicode folding, not a claim of full Windows Unicode15 storage-name parity.
            try wrNeed(paths.insert(path.precomposedStringWithCanonicalMapping.folding(options:.caseInsensitive,locale:Locale(identifier:"en_US_POSIX"))).inserted,.structure)
            if kinds[id] == "document" { try wrNeed(Data(r.str("relative_path").utf8) == Data(path.utf8),.structure) }
        }
        for (id,r) in rows where kinds[id] == "tree_order" {
            let p = try parent(r); try wrNeed(orders[p] == nil && (p.isEmpty || folders.contains(p)),.structure); orders[p] = r
            let expected = try Set(nodes.filter { try parent($0.value) == p && $0.value.get("is_deleted") == .bool(false) }.keys)
            try wrNeed(Set(strings(r.get("children"))) == expected,.structure)
        }
        try wrNeed(Set(orders.keys) == folders.union([""]),.structure)
        let root = try plan.str("root_id"), memberIDs = try Set([root,plan.str("body_id"),plan.str("empty_id"),plan.str("root_order_id")])
        try wrNeed(roles["members"] == memberIDs && folders.contains(root),.structure)
        for id in memberIDs {
            let r = try lookup(rows,id)
            if kinds[id] != "tree_order" { try wrNeed(r.get("is_deleted") == .bool(false),.structure) }
            var current = kinds[id] == "tree_order" ? try parent(r) : id
            var seen = Set<String>()
            while current != root && !current.isEmpty {
                try wrNeed(seen.insert(current).inserted,.structure); current = try parent(lookup(rows,current))
            }
            try wrNeed(current == root,.structure)
        }
        var ancestors = Set<String>(), p = try parent(lookup(rows,root))
        let targetParent = try plan.get("parent_id"); try wrNeed((p.isEmpty ? WindowsJSON.null : .string(p)) == targetParent,.structure)
        while !p.isEmpty { try wrNeed(ancestors.insert(p).inserted,.structure); p = try parent(lookup(rows,p)) }
        var references = ancestors
        for r in orders.values where try ancestors.union([""]).contains(parent(r)) {
            references.insert(try r.str("tree_order_id")); references.formUnion(try strings(r.get("children")))
        }
        references.subtract(memberIDs); try wrNeed(roles["references"] == references,.reference)
        for (idField,nameField,isEmpty) in [("body_id","body_name",false),("empty_id","empty_name",true)] {
            let r = try lookup(rows,plan.str(idField)), meta = try body(r.get("content"))
            try wrNeed(r.str("name") == plan.str(nameField) && parent(r) == root && Data(r.str("relative_path").utf8) == Data((plan.str("root_path")+"/"+plan.str(nameField)).utf8),.body)
            try wrNeed(meta.equalBytes(isEmpty ? body(.string("")) : plan.get("initial_body")),.body)
        }
        try wrNeed(lookup(rows,plan.str("root_order_id")).get("children") == .array([plan.get("body_id"),plan.get("empty_id")]),.structure)
    }
    static func creation(h: WindowsJSON,values: [String:WindowsJSON],rows: [String:WindowsJSON],plan: WindowsJSON,binding: WindowsJSON,resolve: (WindowsJSON) throws -> WindowsJSON) throws {
        let requests = try lookup(values,"creation-requests.json").array(), links = try h.list("creation")
        try wrNeed(requests.count == 4 && links.count == 4,.creation)
        var batches = Set<String>(), operations = Set<String>()
        let planned = try [[plan.str("root_id")],[plan.str("body_id")],[plan.str("empty_id")],[plan.str("parent_order_id"),plan.str("root_order_id")]]
        for (i,request) in requests.enumerated() {
            let link = links[i], batch = try request.get("batch"), intents = try request.list("ordered_intents"), reply = try resolve(link.get("response_ref")), bid = try batch.str("batch_id")
            try link.keys(["request_index","request_ref","batch_id","operation_ids","response_ref"])
            try wrNeed(link.get("request_index").int() == i+8 && link.get("request_ref").str("artifact_id") == "creation-requests.json" && link.get("request_ref").str("json_pointer") == "/\(i)" && resolve(link.get("request_ref")).equalBytes(request) && link.get("response_ref").str("artifact_id") == "Q\(i+8).body" && link.get("response_ref").str("json_pointer").isEmpty,.creation)
            try uuid(bid); try wrNeed(batches.insert(bid).inserted && link.str("batch_id") == bid && reply.str("batch_id") == bid,.creation)
            let batchSHA = byteHash(WindowsJSON.array(intents).encoded())
            try wrNeed(batch.str("batch_payload_sha256") == batchSHA && reply.str("batch_payload_sha256") == batchSHA,.hash)
            for k in ["project_id","project_sync_mode","migration_epoch"] { try wrNeed(request.get(k).equalBytes(binding.get(k)),.binding) }
            try wrNeed(batch.str("writer_device_id") == plan.str("writer_device_id") && batch.str("contract_version") == "0.2.0" && batch.str("canonical_contract_sha256") == contractSHA && batch.get("sync_protocol_version").int() == 3,.contract)
            try capabilities(batch.get("client_capabilities"),clientCaps)
            let doc = i == 1 || i == 2, base = doc ? "document_commit" : "atomic_structure_commit"
            try reply.keys(["kind","status","applied","batch_id","batch_payload_sha256","results"])
            try wrNeed(request.str("kind") == base+"_request" && reply.str("kind") == base+"_success" && ["committed","replayed"].contains(reply.str("status")) && reply.get("applied") == .bool(true),.creation)
            let results = try reply.list("results")
            try wrNeed(intents.count == planned[i].count && results.count == intents.count && strings(link.get("operation_ids")) == intents.map { try $0.str("operation_id") },.creation)
            for (j,intent) in intents.enumerated() {
                let result = results[j], payload = try intent.get("payload"), op = try intent.str("operation_id"), key = doc ? "document_id" : "entity_id", id = try intent.str(key), r = try lookup(rows,id)
                try uuid(op); try wrNeed(operations.insert(op).inserted && result.str("operation_id") == op && intent.str("batch_id") == bid && intent.get("sequence").int(1) == j+1 && result.get("sequence").int(1) == j+1,.creation)
                try wrNeed(id == planned[i][j] && result.str(key) == id && intent.str("entity_kind") == (i == 0 ? "folder" : doc ? "document" : "tree_order") && intent.str("intent_kind") == (i == 3 ? "reorder" : "create"),.creation)
                try wrNeed(intent.str("payload_sha256") == byteHash(payload.encoded()) && result.get("result_revision").int(1) == r.get("revision").int(1),.creation)
                var baseRevision = 0
                if i == 3 && j == 0 {
                    let old = try lookup(values,"Q7.body").array().filter { try $0.str("tree_order_id") == id }; try wrNeed(old.count == 1,.creation); baseRevision = try old[0].get("revision").int(1)
                }
                try wrNeed(intent.get("base_revision").int() == baseRevision,.creation)
                try payload.keys(i == 0 ? ["name","parent_folder_id"] : doc ? ["content","content_sha256","content_byte_count","is_deleted","name","parent_folder_id","structure_revision"] : ["children","parent_folder_id"])
                for (k,v) in try payload.object() where !["content_sha256","content_byte_count"].contains(k) { try wrNeed(v.equalBytes(r.get(k)),.creation) }
                if doc {
                    try result.keys(["sequence","operation_id","document_id","result_revision","structure_revision","parent_folder_id","name","content_sha256","content_byte_count","is_deleted"])
                    let meta = try body(r.get("content"))
                    try wrNeed(payload.str("content_sha256") == meta.str("sha256") && payload.get("content_byte_count").int() == meta.get("utf8_bytes").int(),.body)
                    for k in ["structure_revision","parent_folder_id","name","content_sha256","content_byte_count","is_deleted"] { try wrNeed(result.get(k).equalBytes(payload.get(k)),.creation) }
                } else { try result.keys(["sequence","operation_id","entity_id","result_revision"]) }
            }
        }
        for n in 3...7 {
            let before = try lookup(values,"Q\(n).body"), after = try lookup(values,"Q\(n+9).body")
            if n <= 4 { try wrNeed(before.equalBytes(after),.creation); continue }
            let kind = n == 5 ? "document" : n == 6 ? "folder" : "tree_order", key = kinds[kind]!.1
            let oldList = try before.array(), newList = try after.array(), oldIDs = try oldList.map { try $0.str(key) }, newIDs = try newList.map { try $0.str(key) }
            let added = try Set(n == 5 ? [plan.str("body_id"),plan.str("empty_id")] : n == 6 ? [plan.str("root_id")] : [plan.str("root_order_id")])
            try wrNeed(Set(oldIDs).count == oldIDs.count && Set(newIDs).count == newIDs.count && Set(oldIDs).isDisjoint(with:added) && Set(newIDs) == Set(oldIDs).union(added),.creation)
            for old in oldList {
                let id = try old.str(key), r = try lookup(rows,id); var wanted = try old.object()
                if try n == 7 && id == plan.str("parent_order_id") {
                    wanted["children"] = try .array(old.list("children") + [plan.get("root_id")]); wanted["revision"] = try r.get("revision"); wanted["updated_at"] = try r.get("updated_at")
                }
                try wrNeed(WindowsJSON.object(wanted).equalBytes(r),.creation)
            }
        }
    }
    static func observations(h: WindowsJSON,values: [String:WindowsJSON],raws: [String:Data],binding: WindowsJSON,resolve: (WindowsJSON) throws -> WindowsJSON) throws -> ([String:Int],Int) {
        let observations = try h.list("observations"), evidence = try h.get("evidence").object(), missingList = try h.list("missing_evidence")
        try wrNeed(observations.count == 16 && evidence.count == 80,.evidence)
        var missing: [String:WindowsJSON] = [:], used = Set<String>(), absent = Set<String>(), counts: [String:Int] = [:]
        for m in missingList { let id = try m.str("evidence_id"); try wrNeed(missing[id] == nil,.evidence); missing[id] = m }
        for (index,o) in observations.enumerated() {
            let n = index+1, table = (3...7).contains(n) || n >= 12, phase = n <= 7 ? "precreate" : n <= 11 ? "creation" : "postcreate"
            try o.keys(["request_index","phase","method","path","query","request_body_sha256","response_ref","http_status","reservation_ref","response_event_ref","evidence_ids"])
            try wrNeed(o.get("request_index").int() == n && o.str("phase") == phase && o.get("response_ref").str("artifact_id") == "Q\(n).body" && o.get("response_ref").str("json_pointer").isEmpty,.evidence)
            var method = "GET", path = "", query: WindowsJSON = .object([:]), payload: WindowsJSON?
            if n == 1 { path = "/auth/v1/user" }
            else if n == 2 { method = "POST"; path = "/rest/v1/rpc/get_sync_handshake"; payload = .object(["p_project_id":try binding.get("project_id"),"p_contract_sha256":.string(contractSHA)]) }
            else if table { path = "/rest/v1/"+tables[n <= 7 ? n-3 : n-12]; query = .object(["project_id":.string("eq."+(try binding.str("project_id"))),"select":.string("*"),"limit":.string("10000")]) }
            else { method = "POST"; path = "/rest/v1/rpc/"+([9,10].contains(n) ? "document_commit" : "atomic_structure_commit"); payload = .object(["p_request":try lookup(values,"creation-requests.json").array()[n-8]]) }
            let hash = byteHash(payload?.encoded(lf:true) ?? Data())
            try wrNeed(o.str("method") == method && o.str("path") == path && o.get("query").equalBytes(query) && o.str("request_body_sha256") == hash,.contract)
            let reserve = try resolve(o.get("reservation_ref")), response = try resolve(o.get("response_event_ref"))
            try wrNeed(o.get("reservation_ref").str("json_pointer").isEmpty && o.get("response_event_ref").str("json_pointer").isEmpty && o.get("reservation_ref").str("artifact_id").hasSuffix("-reserved.json") && o.get("response_event_ref").str("artifact_id").hasSuffix("-response.json"),.evidence)
            try reserve.keys(["request","method","path","http_reserved","writes_reserved","body_sha256"])
            try wrNeed(reserve.get("request").int() == n && reserve.str("method") == method && reserve.str("path") == path && reserve.get("http_reserved").int() == n && reserve.get("writes_reserved").int() == min(4,max(0,n-7)) && reserve.str("body_sha256") == hash,.evidence)
            guard let data = raws["Q\(n).body"] else { throw WindowsReaderError.reference }
            let status = try response.get("status").int()
            try wrNeed(response.get("request").int() == n && response.get("bytes").int() == data.count && response.str("sha256") == byteHash(data) && o.get("http_status").int() == status && (table ? [200,206] : [200]).contains(status),.evidence)
            let fields = ["started_at","received_at","content_range","reported_total","row_count"], ids = fields.map { "Q\(n)."+$0 }
            try wrNeed(strings(o.get("evidence_ids")) == ids,.evidence)
            if table { let rows = try resolve(o.get("response_ref")).array(); try wrNeed(rows.count <= 10000,.size); counts["Q\(n)"] = rows.count }
            for (f,id) in zip(fields,ids) {
                let e = try lookup(evidence,id); try e.keys(["state","value","source_ref","missing_evidence_id"]); used.insert(id)
                if ["started_at","received_at"].contains(f) || table && ["content_range","reported_total"].contains(f) {
                    absent.insert(id)
                    try wrNeed(e.str("state") == "unavailable" && e.get("value") == .null && e.get("source_ref") == .null && e.str("missing_evidence_id") == id,.evidence)
                    let m = try lookup(missing,id); try m.keys(["evidence_id","expected_role","phase","request_index","reason"])
                    try wrNeed(m.str("expected_role") == f && m.str("phase") == phase && m.get("request_index").int() == n && m.str("reason") == "NOT_RETAINED_BY_SOURCE_ENGINE",.evidence)
                } else if table { try wrNeed(e.str("state") == "derived_from_raw" && e.get("value").int() == counts["Q\(n)"] && e.get("source_ref").equalBytes(o.get("response_ref")) && e.get("missing_evidence_id") == .null,.evidence) }
                else { try wrNeed(e.str("state") == "not_applicable" && e.get("value") == .null && e.get("source_ref") == .null && e.get("missing_evidence_id") == .null,.evidence) }
            }
        }
        try wrNeed(used == Set(evidence.keys) && absent == Set(missing.keys),.evidence)
        return (counts,missing.count)
    }
}
