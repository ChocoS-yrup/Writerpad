import Foundation

// iPad-local candidate contract, not Windows wire fields and never an execution grant.
struct ReceiveExecutionCandidate {
    // Native bootID is an opaque app-process lifetime scope, not OS boot attestation.
    struct Draft {
        var endpoint:String?, account:UUID?, project:UUID?, handoffSHA256:String?, targetSHA256:String?
        var runID:UUID?, localProjectID:UUID?, bundleID:String?, bootID:String?, sessionEpoch:Int?
        var timing:SyntheticABTiming?
        var httpLimit:Int?, authLimit:Int?
    }
    struct Comparison: Encodable {
        let local_fields_matched:Bool, unresolved:[String]
        let blocked_reasons = ["retained_only", "real_execution_not_authorized"]
        let execution_allowed = false, baseline_ready = false, baseline_applied = false, app_binding_created = false
    }
    struct RuntimeSnapshot {
        let account:UUID, localProjectID:UUID, bundleID:String, bootID:String, sessionEpoch:Int, sessionExpiresUTCMS:Int
    }
    static func compare(_ draft:Draft,to target:ReviewedReceiveTarget,now:ABRuntimeClock.Sample,runtime:RuntimeSnapshot? = nil) throws -> Comparison {
        var unresolved:[String] = []
        func field<T>(_ v:T?,_ name:String)->T? { if v == nil { unresolved.append(name) };return v }
        let endpoint = field(draft.endpoint,"endpoint"),account = field(draft.account,"account"),project = field(draft.project,"project")
        let handoff = field(draft.handoffSHA256,"handoff_sha256"),targetSHA = field(draft.targetSHA256,"target_sha256")
        let run = field(draft.runID,"run_id"),local = field(draft.localProjectID,"local_project_id"),bundle = field(draft.bundleID,"bundle_id")
        let boot = field(draft.bootID,"boot_id"),epoch = field(draft.sessionEpoch,"session_epoch"),timing = field(draft.timing,"timing")
        let http = field(draft.httpLimit,"http_limit"),auth = field(draft.authLimit,"auth_limit")
        if let endpoint {
            guard let c = URLComponents(string:endpoint) else { throw WindowsReaderError.binding }
            try wrNeed(c.scheme == "https" && c.host != nil && c.user == nil && c.password == nil && c.port == nil && (c.path == "" || c.path == "/") && c.query == nil && c.fragment == nil && endpoint == target.binding.str("endpoint"),.binding)
        }
        if let account { try wrNeed(account.uuidString.lowercased() == target.binding.str("account_id"),.binding) }
        if let project { try wrNeed(project.uuidString.lowercased() == target.binding.str("project_id"),.binding) }
        if let handoff { try wrNeed(handoff == target.review.handoff_sha256,.pin) }
        if let targetSHA { try wrNeed(targetSHA == target.targetSHA256,.pin) }
        if let run {
            let id = run.uuidString.lowercased()
            try wrNeed(id != target.sourceRun && id != target.sourceWriterDeviceID && !target.entities.contains{$0.id == id} && run != account && run != project,.binding)
        }
        if let local {
            let id = local.uuidString.lowercased()
            try wrNeed(local != project && local != run && local != account && id != target.sourceRun && id != target.sourceWriterDeviceID && !target.entities.contains{$0.id == id},.binding)
        }
        if let bundle { try wrNeed(bundle == ProtectedBoundaryContainer.bundleID,.binding) }
        if let boot { try wrNeed(!boot.isEmpty && boot.utf8.count <= 128 && boot.utf8.allSatisfy { $0 >= 33 && $0 <= 126 },.binding) }
        if let epoch { try abInteger(epoch) }
        if let timing { try timing.validate();try abInteger(now.utcMS);try abInteger(now.monoMS);try abNeed(timing.requestMS <= 60000 && timing.notBeforeUTCMS <= now.utcMS && now.utcMS < timing.expiresUTCMS,.window) }
        if let http { try wrNeed(http == 14,.contract) };if let auth { try wrNeed(auth == 2,.contract) }
        if let runtime {
            try abInteger(runtime.sessionEpoch);try abInteger(runtime.sessionExpiresUTCMS,1)
            try abNeed(now.utcMS < runtime.sessionExpiresUTCMS,.sessionExpired)
            if let account { try wrNeed(account == runtime.account,.binding) }
            if let local { try wrNeed(local == runtime.localProjectID,.binding) }
            if let bundle { try wrNeed(bundle == runtime.bundleID,.binding) }
            if let boot { try wrNeed(boot == runtime.bootID,.binding) }
            if let epoch { try wrNeed(epoch == runtime.sessionEpoch,.binding) }
            if let timing { try abNeed(timing.expiresUTCMS <= runtime.sessionExpiresUTCMS,.sessionExpired) }
        } else { unresolved.append("runtime_snapshot") }
        // Matching local fields is not evidence of schema finalization, freshness or approval.
        return .init(local_fields_matched:unresolved.isEmpty,unresolved:unresolved)
    }
    static func requireExecution() throws { throw ReceiveConnectionError.closed }
}
