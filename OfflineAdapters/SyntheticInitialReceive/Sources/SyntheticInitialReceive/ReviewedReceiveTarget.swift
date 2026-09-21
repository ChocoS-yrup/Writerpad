import Foundation

// Constructed only after the strict retained reader succeeds. Never a live/baseline capability.
struct ReviewedReceiveTarget: CustomStringConvertible, CustomReflectable {
    struct Entity: Equatable {
        let id:String, kind:String, role:String
        let revision:Int?, structureRevision:Int?, bodySHA256:String?, bodyBytes:Int?
    }
    let review:WindowsHandoffReview
    let binding:WindowsJSON, sourceRun:String, targetSHA256:String
    let entities:[Entity]
    private let expectedRows:[String:WindowsJSON], roles:[String:Set<String>], plan:WindowsJSON
    var description:String { "ReviewedReceiveTarget(retained, unverified baseline)" }
    var customMirror:Mirror { Mirror(self,children:EmptyCollection<(label:String?,value:Any)>()) }
    private init(review:WindowsHandoffReview,binding:WindowsJSON,sourceRun:String,targetSHA256:String,entities:[Entity],rows:[String:WindowsJSON],roles:[String:Set<String>],plan:WindowsJSON) {
        self.review = review;self.binding = binding;self.sourceRun = sourceRun;self.targetSHA256 = targetSHA256;self.entities = entities;expectedRows = rows;self.roles = roles;self.plan = plan
    }
    static func read(portable:Data,expected:WindowsHandoffExpectation) throws -> Self {
        let files = try WindowsHandoffReader.files(from:portable)
        let review = try WindowsHandoffReader.review(files:files,expected:expected)
        let h = try WindowsJSON.decode(files["handoff.json"]!),target = try h.get("target")
        var artifacts:[String:WindowsJSON] = [:]
        for artifact in try h.list("artifacts") { artifacts[try artifact.str("artifact_id")] = try WindowsJSON.decode(files[artifact.str("path")]!) }
        var entities:[Entity] = [], rows:[String:WindowsJSON] = [:], roles:[String:Set<String>] = [:]
        for role in ["members","references","context_only"] {
            roles[role] = []
            for item in try target.list(role) {
                let id = try item.str("entity_id"),kind = try item.str("entity_kind"),refs = try item.list("source_refs")
                guard let ref = refs.first,let artifact = try artifacts[ref.str("artifact_id")] else { throw WindowsReaderError.reference }
                let row = try artifact.pointer(ref.str("json_pointer"));rows[id] = row;roles[role]!.insert(id)
                let fields = try row.object(), special = try kind == "document" && row.str("relative_path").hasPrefix("__antigravity__/")
                let body = kind == "document" && !special ? try WindowsHandoffReader.body(row.get("content")) : nil
                // Base review permits special metadata only as context; its revisions are not verified.
                entities.append(try .init(id:id,kind:kind,role:role,revision:special ? nil : fields["revision"]?.int(1),structureRevision:special ? nil : fields["structure_revision"]?.int(1),bodySHA256:body?.str("sha256"),bodyBytes:body?.get("utf8_bytes").int()))
            }
        }
        return try Self(review:review,binding:expected.binding,sourceRun:h.str("source_run_id"),targetSHA256:byteHash(files["target.json"]!),entities:entities.sorted { $0.id < $1.id },rows:rows,roles:roles,plan:artifacts["plan.json"]!)
    }
    // Compares target/reference rows and returns a whole visible-row fingerprint for A/B callers.
    // No HTTP count, time, Auth, handshake, freshness or apply authority is inferred here.
    func compare(_ tables:[String:[WindowsJSON]]) throws -> String {
        try wrNeed(Set(tables.keys) == Set(["documents","folders","tree_orders"]),.shape)
        var rows:[String:WindowsJSON] = [:], kinds:[String:String] = [:], special = Set<String>()
        for kind in ["document","folder","tree_order"] {
            let (table,key,_) = WindowsHandoffReader.kinds[kind]!
            for row in tables[table]! {
                try WindowsHandoffReader.row(row,kind:kind,project:binding.str("project_id"))
                let id = try row.str(key);try wrNeed(rows[id] == nil,.reference);rows[id] = row;kinds[id] = kind
                if kind == "document",try row.str("relative_path").hasPrefix("__antigravity__/") { special.insert(id) }
            }
        }
        for role in ["members","references"] {
            for id in roles[role]! { guard let row = rows[id],let expected = expectedRows[id] else { throw WindowsReaderError.reference };try wrNeed(row.equalBytes(expected),.body) }
        }
        try WindowsHandoffReader.graph(rows:rows,kinds:kinds,special:special,roles:roles,plan:plan)
        return byteHash(WindowsJSON.object(rows).encoded(lf:true))
    }
    var sourceWriterDeviceID: String { get throws { try plan.str("writer_device_id") } }
    func requireApplyInput() throws { throw WindowsReaderError.unverified }
}
