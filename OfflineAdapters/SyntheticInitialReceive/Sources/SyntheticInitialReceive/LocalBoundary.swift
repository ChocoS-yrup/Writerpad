import Foundation

public enum LocalBoundaryError: String, Error {
    case bundle, identity, unsupportedInput, realContractUnresolved
    case unknownProtectionState, protectedData, binding, state, content, incomplete, writeNotObserved
}

/// No conversion from an observation/proposal/real candidate to a synthetic input is provided.
public enum LocalBoundaryInput {
    case synthetic(SyntheticInput)
    case observation
    case proposal
    case realCandidate
}

public struct LocalBoundaryContext {
    public static let expectedBundle = "com.chocos.writerpad.autosavevalidation"
    public let declaredBundle: String
    public let syntheticLocalIdentity: String
    public let workspace: URL
    public init(declaredBundle: String, syntheticLocalIdentity: String, workspace: URL) {
        self.declaredBundle = declaredBundle
        self.syntheticLocalIdentity = syntheticLocalIdentity
        self.workspace = workspace
    }
}

/// Five independent synthetic payloads, not the app's SQLite/TXT formats.
public enum LocalStoragePart: String, Codable, CaseIterable {
    case bodies, metadata, documentBaseline, folderBaseline, treeOrderBaseline
}
public enum LocalBoundaryPhase: String, Codable { case bound, applying, syntheticReady }
public struct LocalBoundaryBinding: Codable, Equatable {
    public let version: Int
    public let declaredBundle: String
    public let root: String
    public let localIdentity: String
    public let sourceIdentity: String
    public let fixtureID: String
    public let inputDigest: String
    public let resultDigest: String
}

/// Readback is mandatory. A missing protection observation is not equivalent to clean.
public struct LocalStorageView: Equatable {
    public var binding: LocalBoundaryBinding?
    public var phase: LocalBoundaryPhase?
    public var parts: [LocalStoragePart: Data]
    public var completionDigest: String?
    public var hasUnsentDraft: Bool?
    public var hasUnexpectedData: Bool?
    public init(binding: LocalBoundaryBinding? = nil, phase: LocalBoundaryPhase? = nil,
                parts: [LocalStoragePart: Data] = [:], completionDigest: String? = nil,
                hasUnsentDraft: Bool?, hasUnexpectedData: Bool?) {
        self.binding = binding; self.phase = phase; self.parts = parts
        self.completionDigest = completionDigest
        self.hasUnsentDraft = hasUnsentDraft; self.hasUnexpectedData = hasUnexpectedData
    }
}

/// The production app has no implementation of this protocol in this package.
/// All writers must share the same exclusive lock. Methods have no silent-success defaults.
public protocol LocalBoundaryStorage: AnyObject {
    func withExclusiveAccess(_ operation: () throws -> Void) throws
    func read() throws -> LocalStorageView
    func bind(_ binding: LocalBoundaryBinding) throws
    func setPhase(_ phase: LocalBoundaryPhase) throws
    func write(_ data: Data, part: LocalStoragePart) throws
    func setCompletion(_ digest: String) throws
}

public struct LocalBoundaryReceipt: Encodable, Equatable {
    public let synthetic_boundary_ready: Bool
    public let input_digest: String
    public let baseline_ready = false
    public let baseline_applied = false
    public let execution_allowed = false
    public let app_binding_created = false
    public let editing_allowed = false
    public let sending_allowed = false
    public let automatic_receive_allowed = false
}

public enum LocalBoundary {
    /// Validation precedes the only dependency factory. There is no network/auth/app factory.
    public static func prepare(context: LocalBoundaryContext, input: LocalBoundaryInput,
                               makeStorage: (LocalBoundaryBinding) throws -> any LocalBoundaryStorage) throws -> LocalBoundarySession {
        let (binding, plan) = try materials(context: context, input: input, physical: false)
        return LocalBoundarySession(binding: binding, plan: plan, store: try makeStorage(binding))
    }

    /// Explicit host-only physical route. No app container, network or real candidate is accepted.
    public static func preparePhysical(context: LocalBoundaryContext, input: LocalBoundaryInput,
                                       checkpoint: @escaping (String) throws -> Void = { _ in }) throws -> LocalBoundarySession {
        let (binding, plan) = try materials(context: context, input: input, physical: true)
        let store = try PhysicalBoundaryStorage(workspace: context.workspace, binding: binding, checkpoint: checkpoint)
        return LocalBoundarySession(binding: binding, plan: plan, store: store)
    }

    static func prepareProtected(context: LocalBoundaryContext, input: LocalBoundaryInput,
                                 container: ProtectedBoundaryContainer, access: PhysicalStorageAccess) throws -> LocalBoundarySession {
        let (binding, plan) = try materials(context: context, input: input, physical: true,
            expectedBundle: ProtectedBoundaryContainer.bundleID, validateWorkspace: container.validate)
        let store = try PhysicalBoundaryStorage(workspace: context.workspace, binding: binding,
            validateWorkspace: { try container.validate(context.workspace) }, access: access, protectedContainer: container)
        return LocalBoundarySession(binding: binding, plan: plan, store: store)
    }

    private static func materials(context: LocalBoundaryContext, input: LocalBoundaryInput,
                                  physical: Bool, expectedBundle: String = LocalBoundaryContext.expectedBundle,
                                  validateWorkspace: ((URL) throws -> Void)? = nil) throws -> (LocalBoundaryBinding, [LocalStoragePart: Data]) {
        guard context.declaredBundle == expectedBundle else { throw LocalBoundaryError.bundle }
        let synthetic: SyntheticInput
        switch input {
        case .synthetic(let value): synthetic = value
        case .observation, .proposal: throw LocalBoundaryError.unsupportedInput
        case .realCandidate: throw LocalBoundaryError.realContractUnresolved
        }
        guard context.syntheticLocalIdentity == synthetic.manifest.localIdentity else { throw LocalBoundaryError.identity }
        // This initializer only checks the existing disposable namespace; it opens no store/lock.
        let legacyRoot: URL
        if let validateWorkspace = validateWorkspace {
            try validateWorkspace(context.workspace)
            legacyRoot = context.workspace.appendingPathComponent("store")
        } else { legacyRoot = try SyntheticAdapter(workspace: context.workspace).root }
        try SafeFiles.checked(legacyRoot)
        // Both routes reject the earlier adapter's store; it cannot become this store's baseline.
        guard try SafeFiles.attributes(legacyRoot) == nil else { throw LocalBoundaryError.protectedData }
        let root = physical ? context.workspace.appendingPathComponent("physical-boundary", isDirectory: true) : legacyRoot
        try SafeFiles.checked(root)
        let plan = try LocalBoundarySession.payloads(synthetic)
        let hashes = LocalStoragePart.allCases.map {
            DigestEntry(path: $0.rawValue, bytes: plan[$0]!.count, sha256: byteHash(plan[$0]!))
        }.sorted { $0.path < $1.path }
        let protectedPhysical = physical && expectedBundle == ProtectedBoundaryContainer.bundleID && validateWorkspace != nil
        let binding = LocalBoundaryBinding(version: protectedPhysical ? 2 : 1, declaredBundle: context.declaredBundle,
            root: protectedPhysical ? ProtectedBoundaryContainer.relativeWorkspace + "/physical-boundary" : root.path,
            localIdentity: synthetic.manifest.localIdentity, sourceIdentity: synthetic.manifest.sourceIdentity,
            fixtureID: synthetic.manifest.fixtureID, inputDigest: synthetic.digest,
            resultDigest: byteHash(try canonical(hashes)))
        return (binding, plan)
    }
}

public final class LocalBoundarySession {
    public let binding: LocalBoundaryBinding
    private let plan: [LocalStoragePart: Data]
    private let store: any LocalBoundaryStorage
    fileprivate init(binding: LocalBoundaryBinding, plan: [LocalStoragePart: Data], store: any LocalBoundaryStorage) {
        self.binding = binding; self.plan = plan; self.store = store
    }

    // Sealed fresh A/B input only. This reuses physical/readback mechanics, not the old fixture schema.
    static func offlineAdmission(_ plan:ReceiveAdmissionPlan,binding:LocalBoundaryBinding,store:any LocalBoundaryStorage) throws -> LocalBoundarySession {
        try plan.check()
        guard binding.inputDigest == plan.digest && binding.resultDigest == plan.resultDigest else { throw LocalBoundaryError.binding }
        return LocalBoundarySession(binding:binding,plan:plan.parts,store:store)
    }

    fileprivate static func payloads(_ input: SyntheticInput) throws -> [LocalStoragePart: Data] {
        let m = input.manifest
        // Data encodes as base64 so CRLF and canonically equivalent Unicode remain byte-distinct.
        let bodies = input.outputs.filter { $0.key.hasPrefix("tree/") }
        struct DocumentBase: Encodable { let node: FixtureManifest.Node; let body: FixtureManifest.Body }
        let documents = m.bodies.map { body in DocumentBase(node: m.nodes.first { $0.id == body.node }!, body: body) }
        return [.bodies: try canonical(bodies), .metadata: try canonical(m.nodes),
                .documentBaseline: try canonical(documents),
                .folderBaseline: try canonical(m.nodes.filter { $0.kind == "folder" }),
                .treeOrderBaseline: try canonical(m.orders)]
    }

    private func audit(_ view: LocalStorageView) throws {
        guard let draft = view.hasUnsentDraft, let foreign = view.hasUnexpectedData else { throw LocalBoundaryError.unknownProtectionState }
        guard !draft && !foreign else { throw LocalBoundaryError.protectedData }
        if view.binding == nil {
            guard view.phase == nil && view.parts.isEmpty && view.completionDigest == nil else { throw LocalBoundaryError.state }
            return
        }
        guard view.binding == binding else { throw LocalBoundaryError.binding }
        guard let phase = view.phase else { throw LocalBoundaryError.state }
        for (part, data) in view.parts { guard plan[part] == data else { throw LocalBoundaryError.content } }
        if phase == .bound && (!view.parts.isEmpty || view.completionDigest != nil) { throw LocalBoundaryError.state }
        if let digest = view.completionDigest {
            guard digest == binding.resultDigest && view.parts == plan else { throw LocalBoundaryError.incomplete }
        }
        if phase == .syntheticReady {
            guard view.completionDigest == binding.resultDigest && view.parts == plan else { throw LocalBoundaryError.incomplete }
        }
    }

    private func checked() throws -> LocalStorageView {
        let view = try store.read()
        try audit(view)
        return view
    }
    private func requireEqual(_ expected: LocalStorageView) throws {
        guard try checked() == expected else { throw LocalBoundaryError.writeNotObserved }
    }

    @discardableResult
    public func apply() throws -> LocalBoundaryReceipt {
        var calls = 0, finished = false
        try store.withExclusiveAccess {
            calls += 1
            guard calls == 1 else { throw LocalBoundaryError.state }
            var view = try checked()
            if view.binding == nil {
                try store.bind(binding)
                view.binding = binding; view.phase = .bound
                try requireEqual(view)
            }
            if view.phase == .bound {
                try store.setPhase(.applying)
                view.phase = .applying
                try requireEqual(view)
            }
            if view.phase == .applying {
                for part in LocalStoragePart.allCases where view.parts[part] == nil {
                    // Recheck guards and readback each time; a TXT-only success is never enough.
                    try requireEqual(view)
                    try store.write(plan[part]!, part: part)
                    view.parts[part] = plan[part]!
                    try requireEqual(view)
                }
                if view.completionDigest == nil {
                    try requireEqual(view)
                    try store.setCompletion(binding.resultDigest)
                    view.completionDigest = binding.resultDigest
                    try requireEqual(view)
                }
                try store.setPhase(.syntheticReady)
                view.phase = .syntheticReady
                try requireEqual(view)
            }
            try requireEqual(view)
            guard view.phase == .syntheticReady else { throw LocalBoundaryError.incomplete }
            finished = true
        }
        guard calls == 1 && finished else { throw LocalBoundaryError.writeNotObserved }
        return receipt
    }

    public func snapshot() throws -> [LocalStoragePart: Data] {
        var result: [LocalStoragePart: Data] = [:]
        var calls = 0, finished = false
        try store.withExclusiveAccess {
            calls += 1
            guard calls == 1 else { throw LocalBoundaryError.state }
            let view = try checked()
            guard view.phase == .syntheticReady else { throw LocalBoundaryError.incomplete }
            result = view.parts
            finished = true
        }
        guard calls == 1 && finished else { throw LocalBoundaryError.writeNotObserved }
        return result
    }

    private var receipt: LocalBoundaryReceipt {
        LocalBoundaryReceipt(synthetic_boundary_ready: true, input_digest: binding.inputDigest)
    }
}
