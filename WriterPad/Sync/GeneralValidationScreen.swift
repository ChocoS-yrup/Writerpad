import CryptoKit
import Foundation
import SQLite3
import SwiftUI

/// Fresh, read-only logical SQLite and workspace checks at each wire boundary.
/// No WAL checkpoint, backup, migration, journal repair, or source-file write.
struct GeneralValidationLocalProbe: Sendable {
    let syncURL: URL
    let metadataURL: URL
    let workspace: URL
    // A planning copy hashes its files under the original logical workspace
    // identity. File reads still use only `workspace`.
    var fileIdentityRoot: URL? = nil
    struct Snapshot: Equatable, Sendable {
        let syncHash: String
        let metadataHash: String
        let filesHash: String
        let stage: GeneralValidationPlan.Stage?
        var savedForUpdate = false
    }
    /// Foundation may enumerate `/private/var/...` for a root written as
    /// `/var/...`. Normalize both sides before checking containment or deriving
    /// an identity; slicing the unnormalized path can invent parent directories.
    static func relativePath(of file: URL, under root: URL) throws -> String {
        guard file.isFileURL, root.isFileURL else { throw GeneralValidationFailure.denied }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let child = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard child.count > base.count, child.starts(with: base) else { throw GeneralValidationFailure.denied }
        return child.dropFirst(base.count).joined(separator: "/")
    }
    func capture(savedForUpdate: Bool = false) throws -> Snapshot {
        let (syncHash, stage, _) = try database(syncURL, checkPlan: true)
        guard !savedForUpdate || stage == .sendUpdate else { throw GeneralValidationFailure.denied }
        let (metadataHash, _, _) = try database(metadataURL, checkPlan: false)
        guard try workspace.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]).isSymbolicLink != true else { throw GeneralValidationFailure.denied }
        let root = workspace.resolvingSymlinksInPath().standardizedFileURL
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        var enumerationFailed = false
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
            errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw GeneralValidationFailure.denied }
        var files: [String] = [], bytes = 0
        for case let file as URL in iterator {
            let value = try file.resourceValues(forKeys: Set(keys))
            guard value.isSymbolicLink != true else { throw GeneralValidationFailure.denied }
            guard files.count < 1_024 else { throw GeneralValidationFailure.denied }
            let relative = "/" + (try Self.relativePath(of: file, under: root))
            if value.isDirectory == true {
                files.append("directory:" + relative); continue
            }
            guard value.isRegularFile == true else { throw GeneralValidationFailure.denied }
            guard files.count < 1_024, let size = value.fileSize, size <= 16_777_216 else { throw GeneralValidationFailure.denied }
            bytes += size; guard bytes <= 67_108_864 else { throw GeneralValidationFailure.denied }
            files.append(relative + ":" + Self.hash(try Data(contentsOf: file)))
        }
        guard !enumerationFailed else { throw GeneralValidationFailure.denied }
        let bodyURL = root.appendingPathComponent("메인/원고/" + GeneralValidationPlan.name)
        if let stage {
            if stage == .receiveWindows {
                if GeneralValidationPlan.editorEnabled {
                    guard try Data(contentsOf: bodyURL) == Data(GeneralValidationPlan.initial.utf8) else { throw GeneralValidationFailure.denied }
                } else { guard !FileManager.default.fileExists(atPath: bodyURL.path) else { throw GeneralValidationFailure.denied } }
            } else {
                let expected = stage == .sendUpdate && !savedForUpdate ? GeneralValidationPlan.incoming : GeneralValidationPlan.outgoing
                guard try Data(contentsOf: bodyURL) == Data(expected.utf8) else { throw GeneralValidationFailure.denied }
            }
        } else {
            guard try Data(contentsOf: bodyURL) == Data(GeneralValidationPlan.final.utf8) else { throw GeneralValidationFailure.denied }
        }
        return Snapshot(syncHash: syncHash, metadataHash: metadataHash,
                        filesHash: Self.hash(Data(((fileIdentityRoot ?? root).path + "\n" + files.sorted().joined(separator: "\n")).utf8)), stage: stage, savedForUpdate: savedForUpdate)
    }
    private static func hash(_ data: Data) -> String {
        // The same complete SHA-256, with byte encoding rather than 32 locale
        // formatter allocations per database row and per guard invocation.
        let hex = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []; bytes.reserveCapacity(64)
        for byte in SHA256.hash(data: data) {
            bytes.append(hex[Int(byte >> 4)]); bytes.append(hex[Int(byte & 15)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
    func metadataImage() throws -> GeneralValidationMetadataImage { try database(metadataURL, checkPlan: false).2 }
    private func database(_ url: URL, checkPlan: Bool) throws -> (String, GeneralValidationPlan.Stage?, GeneralValidationMetadataImage) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close_v2(db) }; throw GeneralValidationFailure.denied
        }
        defer { sqlite3_close_v2(db) }
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw GeneralValidationFailure.denied }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        func rows(_ sql: String, typed: Bool = false) throws -> [[String]] {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { throw GeneralValidationFailure.denied }
            defer { sqlite3_finalize(st) }
            var result: [[String]] = [], bytes = 0
            while true {
                let code = sqlite3_step(st)
                if code == SQLITE_DONE { return result }
                guard code == SQLITE_ROW, result.count < 100_000 else { throw GeneralValidationFailure.denied }
                var values: [String] = []
                for column in 0..<sqlite3_column_count(st) {
                    let type = sqlite3_column_type(st, column)
                    let count = Int(sqlite3_column_bytes(st, column)); bytes += count
                    guard bytes <= 67_108_864 else { throw GeneralValidationFailure.denied }
                    if typed {
                        if let pointer = sqlite3_column_blob(st, column) {
                            values.append("\(type):" + Data(bytes: pointer, count: count).base64EncodedString())
                        } else {
                            guard count == 0 else { throw GeneralValidationFailure.denied }
                            values.append("\(type):")
                        }
                        continue
                    }
                    if type == SQLITE_NULL { values.append("null") }
                    else if type == SQLITE_BLOB {
                        if let blob = sqlite3_column_blob(st, column) {
                            values.append("blob:" + Data(bytes: blob, count: count).base64EncodedString())
                        } else { values.append("blob:") }
                    } else if let text = sqlite3_column_text(st, column) {
                        values.append(String(cString: text))
                    } else { throw GeneralValidationFailure.denied }
                }
                result.append(values)
            }
        }
        var stage: GeneralValidationPlan.Stage? = .receiveWindows
        if checkPlan {
            let local = GeneralValidationPlan.local.rawValue.uuidString.lowercased(), server = GeneralValidationPlan.server.uuidString.lowercased()
            let filter = "local_project_id='\(local)'"
            let docs = try rows("SELECT document_id,server_revision,base_hash,parent_folder_id,name,structure_revision,is_deleted,project_id,server_path FROM sync_documents WHERE \(filter)")
            let control = "6cbe47cd-67e5-5e27-8dbf-f3ae59255d52"
            guard docs.count == 1 || docs.count == 2, docs.allSatisfy({ $0[6] == "0" && $0[7] == server }),
                  docs.contains(where: { $0[0] == control && $0[1] == "1" && $0[2] == "e290f19f8c47350c5b9b6e7314aadea1477508174b770860040148280517e1f6" }),
                  try rows("SELECT COUNT(*) FROM sync_folders WHERE \(filter)").first?.first == "11",
                  try rows("SELECT COUNT(*) FROM sync_folders WHERE \(filter) AND folder_id='\(GeneralValidationPlan.parent.uuidString.lowercased())' AND project_id='\(server)' AND name='원고' AND server_revision=1 AND is_deleted=0").first?.first == "1",
                  try rows("SELECT COUNT(*) FROM sync_tree_orders WHERE \(filter)").first?.first == "12"
            else { throw GeneralValidationFailure.denied }
            let target = docs.first { $0[0] == GeneralValidationPlan.document.uuidString.lowercased() }
            if let target {
                guard target[3] == GeneralValidationPlan.parent.uuidString.lowercased(), target[4] == GeneralValidationPlan.name, target[5] == "1", target[8] == "메인/원고/" + GeneralValidationPlan.name else { throw GeneralValidationFailure.denied }
                let expected: String
                switch target[1] {
                case String(GeneralValidationPlan.incomingRevision): stage = .sendUpdate; expected = GeneralValidationPlan.incoming
                case String(GeneralValidationPlan.outgoingRevision): stage = .receiveFinal; expected = GeneralValidationPlan.outgoing
                case String(GeneralValidationPlan.finalRevision): stage = nil; expected = GeneralValidationPlan.final
                case "3" where GeneralValidationPlan.editorEnabled: stage = .receiveWindows; expected = GeneralValidationPlan.initial
                default: throw GeneralValidationFailure.denied
                }
                guard target[2] == Self.hash(Data(expected.utf8)) else { throw GeneralValidationFailure.denied }
            } else { guard !GeneralValidationPlan.editorEnabled, docs.count == 1 else { throw GeneralValidationFailure.denied } }
            let order = try rows("SELECT server_revision,children_json,project_id,parent_folder_id FROM sync_tree_orders WHERE \(filter) AND tree_order_id='31eb06be-9cc9-55db-9a05-5882172474ce'")
            guard order.count == 1, order[0][0] == (target == nil ? "1" : "2"), order[0][2] == server,
                  order[0][3] == GeneralValidationPlan.parent.uuidString.lowercased(),
                  try JSONDecoder().decode([String].self, from: Data(order[0][1].utf8)) == (target == nil ? [] : [GeneralValidationPlan.document.uuidString.lowercased()])
            else { throw GeneralValidationFailure.denied }
        }
        let tables = try rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").compactMap(\.first)
        guard !tables.isEmpty, tables.count < 100 else { throw GeneralValidationFailure.denied }
        var fingerprints: [String] = []
        var imageTables: [String: GeneralValidationMetadataImage.Table] = [:]
        for name in tables {
            let safe = name.replacingOccurrences(of: "\"", with: "\"\"")
            let values = try rows("SELECT * FROM \"\(safe)\"", typed: true)
            let schema = try rows("PRAGMA table_info(\"\(safe)\")")
            let columns = schema.map { $0[1] }
            imageTables[name] = .init(columns: columns, schema: schema, rows: values)
            let encoder = JSONEncoder()
            let encoded = try values.map { try encoder.encode($0) }.map(Self.hash).sorted()
            fingerprints.append(name + ":" + Self.hash(try JSONEncoder().encode(schema)) + ":" + Self.hash(Data(encoded.joined(separator: "\n").utf8)))
        }
        let digest = Self.hash(Data(fingerprints.joined(separator: "\n").utf8))
        return (digest, stage, GeneralValidationMetadataImage(tables: imageTables, fullHash: digest))
    }
}

/// Bound to actual authentication and binding/lifecycle epochs. Preparing this
/// local inspection does not restore authentication or authorize server traffic.
@MainActor
final class GeneralValidationScreenModel: ObservableObject {
    @Published private(set) var editor: GeneralValidationEditor?
    @Published var email = ""
    @Published var password = ""
    @Published private(set) var busy = false
    @Published private(set) var ready = false
    @Published private(set) var message = "로그인 후 계정과 로컬 기준을 확인하세요."
    @Published private(set) var stage: GeneralValidationPlan.Stage?
    @Published private(set) var executionReady = false
    @Published private(set) var copyDiagnostic: GeneralValidationPlanningCopy.CopyDiagnostic?
    @Published private(set) var recoveryAvailable: Bool
    private let reviewedRecoverySHA256: String?
    private let reviewedRecoveryID: UUID?
    var runtime: GeneralValidationRuntime?
    private var runtimePrepared: GeneralValidationRuntime.Prepared?
    private let auth: any AuthenticationServicing
    private let binding: @Sendable () async throws -> ProjectSyncBinding?
    private let queueIsEmpty: @Sendable () async throws -> Bool
    private let probe: @Sendable () async throws -> GeneralValidationLocalProbe
    private let bindingEpoch: SyncV2ContractEpoch
    private let projectEpoch: SyncV2ContractEpoch
    private let screenEpoch = SyncV2ContractEpoch()
    private let journalRoot: URL
    private let expirySleep: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> TimeInterval
    private var foreground = false
    private var loginTask: Task<AuthenticationState, Never>?
    private var loginPolicy: ReceiveValidationPolicy?
    private var prepared: Prepared?
    private var execution: GeneralValidationExecution?
    private var transition: GeneralValidationLocalTransition?
    private var expiry: Task<Void, Never>?
    private var completionMessage: String?
    private struct Prepared {
        let snapshot: GeneralValidationLocalProbe.Snapshot
        let probe: GeneralValidationLocalProbe
        let current: @Sendable () throws -> Void
    }
    init(auth: any AuthenticationServicing, bindingEpoch: SyncV2ContractEpoch, projectEpoch: SyncV2ContractEpoch,
         journalRoot: URL, binding: @escaping @Sendable () async throws -> ProjectSyncBinding?,
         queueIsEmpty: @escaping @Sendable () async throws -> Bool,
         probe: @escaping @Sendable () async throws -> GeneralValidationLocalProbe,
         reviewedRecoverySHA256: String? = nil,
         reviewedRecoveryID: UUID? = nil,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         expirySleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.expirySleep = expirySleep
        self.auth = auth; self.bindingEpoch = bindingEpoch; self.projectEpoch = projectEpoch
        self.journalRoot = journalRoot; self.binding = binding; self.queueIsEmpty = queueIsEmpty; self.probe = probe; self.now = now
        self.reviewedRecoverySHA256 = reviewedRecoverySHA256
        self.reviewedRecoveryID = reviewedRecoveryID
        self.recoveryAvailable = !GeneralValidationPlan.editorEnabled && reviewedRecoverySHA256 != nil
    }
    func setForeground(_ active: Bool) {
        foreground = active
        if !active {
            loginPolicy?.invalidate(); loginPolicy = nil
            password = ""; loginTask?.cancel(); loginTask = nil
            invalidate("화면을 벗어나 준비를 중단했습니다.")
        }
    }
    /// Explicit foreground login uses the product auth service directly. It does
    /// not call the dispatcher, restore credentials or start a project read.
    func signIn() async {
        guard foreground, !busy, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.isEmpty else { return }
        invalidate(); busy = true
        defer { busy = false; password = ""; loginTask = nil; loginPolicy = nil }
        let revision = screenEpoch.value
        let policy = ReceiveValidationPolicy.current
        loginPolicy = policy
        do {
            let ticket = try policy.beginAuthentication(foreground: foreground, endpoint: ReceiveValidationPolicy.Configuration.staging)
            let auth = self.auth, email = self.email.trimmingCharacters(in: .whitespacesAndNewlines), password = self.password
            let task = Task {
                await ReceiveValidationPolicy.$operation.withValue(ticket) {
                    await auth.signIn(email: email, password: password)
                }
            }
            loginTask = task
            let result = await task.value
            guard !task.isCancelled, foreground, screenEpoch.value == revision else {
                policy.invalidate(); return
            }
            guard case let .authenticated(account) = result else {
                policy.invalidate(); message = "로그인하지 못했습니다. 계정 정보와 연결 상태를 확인하세요."; return
            }
            try policy.verifyAccount(account.userID, ticket: ticket)
            message = "서버 계정에 로그인했습니다. 계정·로컬 기준을 확인하세요."
        } catch {
            policy.invalidate(); message = "로그인을 시작하지 못했습니다. 시험 계정 설정을 확인하세요."
        }
    }
    func invalidate(_ reason: String = "준비 상태가 끝났습니다. 계정과 로컬 기준을 다시 확인하세요.") {
        runtimePrepared?.capability.stop(); runtimePrepared = nil; executionReady = false
        screenEpoch.advance(); expiry?.cancel(); expiry = nil; execution?.stop(); execution = nil
        transition?.stop(); transition = nil
        prepared = nil; ready = false; stage = nil
        // Authentication/lifecycle expiry ends authority, not a verified result.
        message = completionMessage ?? reason
    }
    private func finishPreparation(_ result: String) {
        completionMessage = result
        invalidate()
    }
    func observeAuthentication() async {
        let stream = await auth.stateUpdates()
        for await _ in stream {
            if Task.isCancelled { return }
            if ready { do { try validatePrepared() } catch { invalidate() } }
        }
    }
    /// Offline copy only: no authentication, handshake, stage reservation or product apply.
    /// Existing stopped journals remain in place and still prevent a receive retry.
    func archiveReviewedReceiveStop() async {
        guard foreground, !busy, recoveryAvailable, let hash = reviewedRecoverySHA256 else { return }
        recoveryAvailable = false
        invalidate("중단 기록을 확인하고 있습니다. 송수신하지 않습니다.")
        password = ""; busy = true
        defer { busy = false }
        let epoch = screenEpoch.value
        do {
            let source = try await probe(), before = try source.capture()
            guard before.stage == .receiveWindows, !before.savedForUpdate, try await queueIsEmpty() else { throw GeneralValidationFailure.denied }
            try GeneralValidationJournal.archiveReviewedFirstReceive(root: journalRoot, expectedSHA256: hash, recoveryID: reviewedRecoveryID) {
                guard foreground, screenEpoch.value == epoch, try source.capture() == before else { throw GeneralValidationFailure.denied }
            }
            message = "중단 기록을 보존했습니다. 로그인 후 계정·로컬 기준을 다시 확인하세요. 송수신하지 않았습니다."
        } catch { message = "중단 기록 보존·재개 준비에 실패했습니다. 재시도하지 말고 기록을 확인하세요." }
    }
    func diagnosePlanningCopy() async {
        guard foreground, !busy else { return }
        invalidate("로컬 복제 진단 중입니다. 송수신하지 않습니다.")
        password = ""; copyDiagnostic = nil; busy = true
        defer { busy = false }
        let version = screenEpoch.value
        do {
            let source = try await probe()
            guard foreground, screenEpoch.value == version else { throw GeneralValidationFailure.denied }
            _ = try source.capture()
            let parent = journalRoot.appendingPathComponent("copy-diagnostics")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            _ = try GeneralValidationPlanningCopy.create(from: source, in: parent) { self.copyDiagnostic = $0 }
            message = "로컬 복제 진단 완료. 전체 해시 일치. 송수신하지 않았습니다."
        } catch {
            if let diagnostic = copyDiagnostic {
                let code = diagnostic.errorCode.map { " \($0)" } ?? ""
                message = "로컬 복제 진단 중단: \(diagnostic.phase.rawValue) · \(diagnostic.database ?? "workspace") · \(diagnostic.errorFamily ?? "validation")\(code). 송수신하지 않았습니다."
            } else { message = "로컬 복제 진단을 시작하지 못했습니다. 로컬 기준과 저장 공간을 확인하세요. 송수신하지 않았습니다." }
        }
    }
    func prepareExecution() async {
        guard !busy, foreground, let runtime else { return }
        await prepare()
        guard ready, stage != nil, let prepared else { return }
        busy = true; defer { busy = false }
        do {
            let value = try await runtime.prepare(probe: prepared.probe, snapshot: prepared.snapshot, current: prepared.current)
            try validatePrepared()
            runtimePrepared = value; executionReady = true
            message = "인증 준비 완료. 승인된 단계만 실행하세요."
        } catch { invalidate("실행 준비를 중단했습니다. 로그인·시험 관문·계약 응답을 확인하세요.") }
    }
    func openEditor() async {
        guard GeneralValidationPlan.editorEnabled, foreground, !busy, stage == .sendUpdate,
              editor == nil, let runtime else { return }
        busy = true; defer { busy = false }
        do {
            try validatePrepared()
            editor = try await runtime.makeEditor()
            try validatePrepared()
            message = "마지막 줄 뒤에 iPad 일반 편집 검증 20260913을 입력하고 줄바꿈 1개를 추가하세요."
        } catch { invalidate("지정 문서 편집기를 열지 못했습니다. 저장하지 않았습니다.") }
    }
    func execute(_ requested: GeneralValidationPlan.Stage) async {
        guard foreground, !busy, executionReady, stage == requested,
              let prepared, let runtimePrepared, let runtime else { return }
        if GeneralValidationPlan.editorEnabled && requested == .sendUpdate {
            do { guard let editor else { throw GeneralValidationEditor.Failure.wrongDraft }; _ = try editor.draft() }
            catch { message = "저장하지 않았습니다. 지정 문서의 추가 줄·마지막 줄바꿈과 한글 조합 완료를 확인하세요."; return }
        }
        busy = true; defer { busy = false }
        do {
            try validatePrepared()
            let result = try await runtime.run(stage: requested, prepared: runtimePrepared, probe: prepared.probe,
                before: prepared.snapshot, journalRoot: journalRoot, editor: editor)
            try prepared.current()
            self.prepared = Prepared(snapshot: result, probe: prepared.probe, current: prepared.current)
            stage = result.stage
            switch requested {
            case .receiveWindows: message = GeneralValidationPlan.editorEnabled ? "Windows 본문 revision 4 · 197바이트 수신 완료. 지정 문서를 일반 편집하세요." : "Windows 본문 revision 1 · 100바이트 수신 완료. 다음은 iPad 저장·송신 1회입니다."
            case .sendUpdate: message = GeneralValidationPlan.editorEnabled ? "iPad 본문 revision 5 · 232바이트 일반 저장·송신 완료. Windows revision 6 송신을 기다리세요." : "iPad 본문 revision 2 · 128바이트 저장·송신 완료. Windows revision 3 송신을 기다리세요."
            case .receiveFinal:
                finishPreparation(GeneralValidationPlan.editorEnabled ? "최종 수신 완료. revision 6 · 269바이트 · 8줄 본문 대조 일치." : "최종 수신 완료. revision 3 · 159바이트 · 5줄 본문 대조 일치.")
            }
        } catch { invalidate("검증을 중단했습니다. 재시도하지 말고 실행 기록과 로컬 저장 상태를 확인하세요.") }
    }
    func prepare() async {
        guard foreground, !busy else { return }
        // An explicit fresh inspection may discover a changed local baseline.
        completionMessage = nil
        invalidate(); busy = true
        defer { busy = false }
        do {
            guard let authEpoch = auth.contractEpoch else { throw GeneralValidationFailure.denied }
            let authVersion = authEpoch.value, bindVersion = bindingEpoch.value, projectVersion = projectEpoch.value, screenVersion = screenEpoch.value
            let policy = ReceiveValidationPolicy.current, ticket = try policy.authorization()
            guard case let .authenticated(account) = await auth.currentState(),
                  let connected = try await binding(), connected.localProjectID == GeneralValidationPlan.local,
                  connected.serverProjectID == GeneralValidationPlan.server, connected.ownerSubject == account.userID,
                  connected.kind == .existingServerProject, try await queueIsEmpty() else { throw GeneralValidationFailure.denied }
            try policy.verifyAccount(account.userID, ticket: ticket)
            let probe = try await probe(), first = try probe.capture(), second = try probe.capture()
            guard first == second, try await queueIsEmpty(), try await binding() == connected,
                  try probe.capture() == first else { throw GeneralValidationFailure.denied }
            let bindingEpoch = self.bindingEpoch, projectEpoch = self.projectEpoch, screenEpoch = self.screenEpoch
            let now = self.now, lifetime = min(300, ticket?.expires.timeIntervalSinceNow ?? 300)
            guard lifetime > 0 else { throw GeneralValidationFailure.denied }
            let deadline = now() + lifetime
            let current: @Sendable () throws -> Void = {
                try Task.checkCancellation()
                guard now() < deadline, authEpoch.isAvailable, authEpoch.value == authVersion,
                      bindingEpoch.isAvailable, bindingEpoch.value == bindVersion,
                      projectEpoch.isAvailable, projectEpoch.value == projectVersion,
                      screenEpoch.value == screenVersion else { throw GeneralValidationFailure.denied }
                try ReceiveValidationPolicy.$operation.withValue(ticket) { _ = try policy.authorization() }
            }
            try current()
            if let stage = first.stage,
               FileManager.default.fileExists(atPath: GeneralValidationJournal.url(root: journalRoot, stage: stage).path) {
                throw GeneralValidationFailure.alreadyReserved
            }
            guard first.stage != nil else {
                finishPreparation("모든 단계가 완료되어 잠겨 있습니다. 완료 요청을 재실행하지 않습니다.")
                return
            }
            prepared = Prepared(snapshot: first, probe: probe, current: current)
            stage = first.stage; ready = true
            message = "계정·로컬 기준 확인 완료. 송수신은 잠겨 있습니다."
            let sleep = expirySleep
            expiry = Task { [weak self] in
                do { try await sleep(lifetime) } catch { return }
                guard !Task.isCancelled, let self, self.screenEpoch.value == screenVersion,
                      self.ready, self.stage != nil else { return }
                self.invalidate("준비 유효 시간이 끝났습니다. 다시 확인하세요.")
            }
        } catch GeneralValidationFailure.alreadyReserved {
            invalidate("이 단계의 실행 기록이 있습니다. 기록 확인 전에는 재실행할 수 없습니다.")
        } catch { invalidate("준비를 중단했습니다. 로그인·작품 연결·파일·대기열 상태를 확인하세요.") }
    }
    func validatePrepared() throws {
        guard foreground, ready, let prepared else { throw GeneralValidationFailure.denied }
        try prepared.current()
        guard try prepared.probe.capture() == prepared.snapshot else { throw GeneralValidationFailure.denied }
    }
    /// Called only by the reviewed stage runner after its requests and bearer are
    /// frozen. The screen itself cannot invent a transport grant or clear a journal.
    func makeExecution(requests: [URLRequest], bearer: String) throws -> GeneralValidationExecution {
        do {
            try validatePrepared()
            guard execution == nil, transition == nil, let prepared, let stage = prepared.snapshot.stage else { throw GeneralValidationFailure.denied }
            try FileManager.default.createDirectory(at: journalRoot, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let value = try GeneralValidationExecution(root: journalRoot, stage: stage, requests: requests, bearer: bearer,
                checkCurrent: prepared.current, checkLocal: {
                    guard try prepared.probe.capture() == prepared.snapshot else { throw GeneralValidationFailure.denied }
                })
            execution = value
            return value
        } catch { invalidate(); throw error }
    }
    /// Internal composition only. Expected checkpoints must come from the reviewed
    /// local mutation plan before execution, never from a post-write recapture.
    func makeStageService(expected: [GeneralValidationLocalProbe.Snapshot],
                          exchange: @escaping GeneralValidationStageService.Exchange) throws
        -> (GeneralValidationStageService, GeneralValidationLocalTransition) {
        do {
            return try makeStageService(plan: GeneralValidationCheckpointPlan(checkpoints: expected), exchange: exchange)
        } catch { invalidate(); throw error }
    }

    /// Build a stage runner from a complete, reviewed checkpoint plan. The
    /// product's current snapshot is checked before the journal is reserved.
    func makeStageService(plan: GeneralValidationCheckpointPlan,
                          exchange: @escaping GeneralValidationStageService.Exchange) throws
        -> (GeneralValidationStageService, GeneralValidationLocalTransition) {
        do {
            try validatePrepared()
            guard execution == nil, transition == nil, let prepared,
                  prepared.snapshot.stage == plan.stage else { throw GeneralValidationFailure.denied }
            try plan.requireStart(prepared.snapshot)
            let transition = try GeneralValidationLocalTransition(expected: plan.checkpoints, capture: { index in
                try prepared.probe.capture(savedForUpdate: plan.checkpoints[index].savedForUpdate)
            }, current: prepared.current)
            try transition.require(stage: plan.stage)
            self.transition = transition
            try FileManager.default.createDirectory(at: journalRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return (GeneralValidationStageService(root: journalRoot, exchange: exchange, current: prepared.current), transition)
        } catch { invalidate(); throw error }
    }
}

struct GeneralValidationSection: View {
    @ObservedObject var model: GeneralValidationScreenModel
    @Environment(\.scenePhase) private var phase
    private enum LoginField { case email, password }
    @FocusState private var loginField: LoginField?
    var body: some View {
        Section("일반 시험 작품 검증") {
            Text("일반동기화 검증 20260910")
            Text(GeneralValidationPlan.editorEnabled ? "일반 편집 · Windows 4 → iPad 5 → Windows 6" : "본문 1개 · Windows 1 → iPad 2 → Windows 3").font(.footnote)
            TextField("이메일", text: $model.email)
                .textContentType(.username).keyboardType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($loginField, equals: .email).submitLabel(.next)
                .onSubmit { loginField = .password }
            SecureField("비밀번호", text: $model.password)
                .textContentType(.password).focused($loginField, equals: .password).submitLabel(.go)
                .onSubmit { loginField = nil; Task { await model.signIn() } }
            Button("로그인") { loginField = nil; Task { await model.signIn() } }
                .disabled(model.busy || model.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.password.isEmpty)
            Button("계정·로컬 기준 확인") { Task { await model.prepare() } }.disabled(model.busy)
            Button("인증·실행 준비") { Task { await model.prepareExecution() } }.disabled(model.busy || model.runtime == nil)
            Button("1. Windows 변경 수신") { Task { await model.execute(.receiveWindows) } }
                .disabled(model.busy || !model.executionReady || model.stage != .receiveWindows)
            if GeneralValidationPlan.editorEnabled {
                Button("지정 문서 일반 편집기 열기") { Task { await model.openEditor() } }
                    .disabled(model.busy || !model.ready || model.stage != .sendUpdate || model.editor != nil)
                if let editor = model.editor {
                    GeneralValidationEditorView(model: editor.model,
                        enabled: !model.busy && model.ready && model.stage == .sendUpdate)
                }
            }
            Button(GeneralValidationPlan.editorEnabled ? "2. 일반 편집 저장·송신 1회" : "2. 합성 본문 저장·송신 1회") { Task { await model.execute(.sendUpdate) } }
                .disabled(model.busy || !model.executionReady || model.stage != .sendUpdate)
            Button(GeneralValidationPlan.editorEnabled ? "3. Windows 최종 변경 수신·8줄 대조" : "3. Windows 최종 변경 수신·5줄 대조") { Task { await model.execute(.receiveFinal) } }
                .disabled(model.busy || !model.executionReady || model.stage != .receiveFinal)
            Text(model.message).font(.footnote)
            Button("로컬 복제 진단") { Task { await model.diagnosePlanningCopy() } }
                .disabled(model.busy)
            if model.recoveryAvailable {
                Button("중단 기록 보존·첫 수신 재개 준비") { Task { await model.archiveReviewedReceiveStop() } }
                    .disabled(model.busy)
            }
            if model.ready { Button("준비 중단") { model.invalidate() } }
            Text("송수신 실행 범위 확인과 승인 후 진행할 수 있습니다.").font(.footnote)
        }
        .onAppear { model.setForeground(phase == .active) }
        .onDisappear { model.setForeground(false) }
        .onChange(of: phase) { _, next in model.setForeground(next == .active) }
        .task { await model.observeAuthentication() }
    }
}
