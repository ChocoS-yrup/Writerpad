import SwiftUI

enum AutosaveDelaySetting {
    static let storageKey = "writerpad.autosave-delay-milliseconds"
    static let defaultMilliseconds = 800
    static let allowedMilliseconds = [500, 800, 1_000, 1_500, 2_000, 3_000]

    static func normalized(_ milliseconds: Int) -> Int {
        allowedMilliseconds.contains(milliseconds) ? milliseconds : defaultMilliseconds
    }

    static func label(for milliseconds: Int) -> String {
        switch milliseconds {
        case 500: "0.5초"
        case 800: "0.8초"
        case 1_000: "1초"
        case 1_500: "1.5초"
        case 2_000: "2초"
        case 3_000: "3초"
        default: label(for: defaultMilliseconds)
        }
    }
}

struct AppearanceSettingsView: View {
    @Binding var isDarkMode: Bool
    @Binding var smartPairsEnabled: Bool
    let projectID: ProjectID?
    let backupStore: (any BackupStoring)?
    let backupPolicyStore: (any BackupPolicyStoring)?
    let projectManager: any ProjectManaging
    let authenticationService: any AuthenticationServicing
    let projectBindingService: any ProjectBindingServicing
    let syncDispatcher: SyncV2Dispatcher?
    let backgroundSyncCoordinator: SyncV2BackgroundSyncCoordinator?
    let editLeaseManager: (any EditLeaseManaging)?
    var handshakeService: SyncV2HandshakeService?
    @Environment(\.dismiss) private var dismiss

    @AppStorage("writerpad.editor-font-family")
    private var fontFamilyRawValue = EditorFontFamily.system.rawValue
    @AppStorage("writerpad.editor-font-size") private var fontSize = 17.0
    @AppStorage("writerpad.editor-line-spacing") private var lineSpacing = 6.0
    @AppStorage("writerpad.editor-horizontal-inset") private var horizontalInset = 64.0
    @AppStorage("writerpad.editor-vertical-inset") private var verticalInset = 30.0
    @AppStorage("writerpad.editor-bold") private var isBold = false
    @AppStorage("writerpad.binder-font-bold-v2") private var isBinderBold = true
    @AppStorage("writerpad.binder-font-larger") private var isBinderFontLarger = false
    @AppStorage("writerpad.editor-typewriter-scrolling")
    private var typewriterScrolling = false
    @AppStorage(AutosaveDelaySetting.storageKey)
    private var autosaveDelayMilliseconds = AutosaveDelaySetting.defaultMilliseconds
    @AppStorage("writerpad.smart-ellipsis-enabled")
    private var smartEllipsisEnabled = true
    @AppStorage("writerpad.smart-quotation-shortcuts-enabled")
    private var smartQuotationShortcutsEnabled = true
    @AppStorage("writerpad.smart-scene-break-enabled")
    private var smartSceneBreakEnabled = true
    @AppStorage("writerpad.restore-last-project-on-launch")
    private var restoresLastProjectOnLaunch = true
    @State private var backupPolicy = BackupPolicy.default
    @State private var hasLoadedBackupPolicy = false
    @State private var backupPolicySaveTask: Task<Void, Never>?
    @State private var backupPolicySaveGeneration = 0
    @State private var backupErrorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("동기화") {
                    NavigationLink {
                        SyncSettingsView(
                            projectManager: projectManager,
                            authenticationService: authenticationService,
                            projectBindingService: projectBindingService,
                            syncDispatcher: syncDispatcher,
                            backgroundSyncCoordinator:
                                backgroundSyncCoordinator,
                            editLeaseManager: editLeaseManager,
                            handshakeService: handshakeService
                        )
                    } label: {
                        Label(
                            "서버 계정 및 작품 연결",
                            systemImage: "arrow.triangle.2.circlepath.icloud"
                        )
                    }
                    .accessibilityIdentifier("writerpad.sync-settings")
                    Text("한 번 로그인한 뒤 전체 작품 동기화와 작품별 예외 연결을 관리합니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("화면") {
                    Toggle("다크 모드", isOn: $isDarkMode)
                        .accessibilityIdentifier("writerpad.dark-mode-toggle")
                    Text("끔 상태에서는 iPad 시스템 모드를 따릅니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("시작") {
                    Toggle(
                        "마지막 작품 자동 열기",
                        isOn: $restoresLastProjectOnLaunch
                    )
                    .accessibilityIdentifier("writerpad.restore-last-project-toggle")
                    Text("끄면 앱을 시작할 때 작품 목록을 표시합니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("편집기") {
                    Picker("글꼴", selection: fontFamily) {
                        ForEach(EditorFontFamily.allCases, id: \.self) { family in
                            Text(family.displayName).tag(family)
                        }
                    }
                    .accessibilityIdentifier("writerpad.editor-font-picker")

                    Stepper("글자 크기  \(fontSize, specifier: "%.0f")pt", value: $fontSize, in: 14...32)
                        .accessibilityIdentifier("writerpad.editor-font-size")
                    Stepper("행간  \(1.6 + lineSpacing / 100, specifier: "%.2f")배", value: $lineSpacing, in: -60...20)
                        .accessibilityIdentifier("writerpad.editor-line-spacing")
                    Stepper("좌우 여백  \(horizontalInset, specifier: "%.0f")pt", value: $horizontalInset, in: 24...120, step: 4)
                        .accessibilityIdentifier("writerpad.editor-horizontal-inset")
                    Stepper("상하 여백  \(verticalInset, specifier: "%.0f")pt", value: $verticalInset, in: 16...80, step: 2)
                        .accessibilityIdentifier("writerpad.editor-vertical-inset")
                    Toggle("굵게", isOn: $isBold)
                        .accessibilityIdentifier("writerpad.editor-bold")
                    Toggle("바인더 글꼴 굵게", isOn: $isBinderBold)
                        .accessibilityIdentifier("writerpad.binder-bold")
                    Toggle("바인더 글꼴 2pt 크게", isOn: $isBinderFontLarger)
                        .accessibilityIdentifier("writerpad.binder-font-larger")
                    Toggle("타자기 스크롤", isOn: $typewriterScrolling)
                        .accessibilityIdentifier("writerpad.editor-typewriter-scrolling")
                    Text("커서가 편집 화면 중앙 부근에 머물도록 스크롤합니다. 동작 줄이기 설정을 존중합니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Picker("자동 저장 대기시간", selection: autosaveDelay) {
                        ForEach(AutosaveDelaySetting.allowedMilliseconds, id: \.self) { milliseconds in
                            Text(AutosaveDelaySetting.label(for: milliseconds))
                                .tag(milliseconds)
                        }
                    }
                    .accessibilityIdentifier("writerpad.autosave-delay")
                }

                Section("입력") {
                    Toggle("스마트 기호 입력", isOn: $smartPairsEnabled)
                        .accessibilityIdentifier("writerpad.smart-pairs-toggle")
                    Toggle("말줄임표 자동 변환", isOn: $smartEllipsisEnabled)
                        .accessibilityIdentifier("writerpad.smart-ellipsis-toggle")
                    Toggle(
                        "특수 인용부호 단축 입력",
                        isOn: $smartQuotationShortcutsEnabled
                    )
                    .accessibilityIdentifier("writerpad.smart-quotation-toggle")
                    Toggle("별표 장면 전환선", isOn: $smartSceneBreakEnabled)
                        .accessibilityIdentifier("writerpad.smart-scene-break-toggle")
                    Text("각 입력 규칙은 모든 작품에서 공통으로 적용됩니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let projectID, backupStore != nil, backupPolicyStore != nil {
                    Section("백업") {
                        Toggle("자동 백업", isOn: Binding(
                            get: { backupPolicy.isAutomaticBackupEnabled },
                            set: { updateBackupPolicy(isAutomatic: $0) }
                        ))
                        Stepper("최근 백업 최대 \(backupPolicy.maximumRecentSnapshots)개", value: Binding(
                            get: { backupPolicy.maximumRecentSnapshots },
                            set: { updateBackupPolicy(maximum: $0) }
                        ), in: 1...500)
                        Stepper("보관 기간 \(backupPolicy.retentionDays)일", value: Binding(
                            get: { backupPolicy.retentionDays },
                            set: { updateBackupPolicy(days: $0) }
                        ), in: 1...3650)
                        Text("고정한 백업은 자동 정리 대상에서 제외됩니다.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("백업 설정은 모든 작품에 공통으로 적용됩니다.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .task { await loadBackupPolicy(for: projectID) }
                }
            }
            .navigationTitle("설정")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
            .alert("백업 설정을 저장하지 못했습니다", isPresented: Binding(
                get: { backupErrorMessage != nil },
                set: { if !$0 { backupErrorMessage = nil } }
            )) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(backupErrorMessage ?? "")
            }
        }
        .onAppear {
            autosaveDelayMilliseconds = AutosaveDelaySetting.normalized(
                autosaveDelayMilliseconds
            )
        }
    }

    private var fontFamily: Binding<EditorFontFamily> {
        Binding(
            get: { EditorFontFamily(rawValue: fontFamilyRawValue) ?? .system },
            set: { fontFamilyRawValue = $0.rawValue }
        )
    }

    private var autosaveDelay: Binding<Int> {
        Binding(
            get: {
                AutosaveDelaySetting.normalized(autosaveDelayMilliseconds)
            },
            set: {
                autosaveDelayMilliseconds = AutosaveDelaySetting.normalized($0)
            }
        )
    }

    private func updateBackupPolicy(isAutomatic: Bool? = nil, maximum: Int? = nil, days: Int? = nil) {
        backupPolicy = BackupPolicy(
            isAutomaticBackupEnabled: isAutomatic ?? backupPolicy.isAutomaticBackupEnabled,
            maximumRecentSnapshots: maximum ?? backupPolicy.maximumRecentSnapshots,
            retentionDays: days ?? backupPolicy.retentionDays
        )
        guard hasLoadedBackupPolicy, let projectID else { return }
        backupPolicySaveTask?.cancel()
        backupPolicySaveGeneration &+= 1
        let generation = backupPolicySaveGeneration
        let policy = backupPolicy
        backupPolicySaveTask = Task {
            await saveBackupPolicy(policy, generation: generation, for: projectID)
        }
    }

    private func loadBackupPolicy(for projectID: ProjectID) async {
        guard !hasLoadedBackupPolicy, let backupPolicyStore else { return }
        do {
            backupPolicy = try await backupPolicyStore.policy(for: projectID)
            hasLoadedBackupPolicy = true
        } catch {
            backupPolicy = .default
            hasLoadedBackupPolicy = true
            backupErrorMessage = error.localizedDescription
        }
    }

    private func saveBackupPolicy(
        _ policy: BackupPolicy,
        generation: Int,
        for projectID: ProjectID
    ) async {
        guard let backupPolicyStore else { return }
        do {
            try Task.checkCancellation()
            try await backupPolicyStore.save(policy, for: projectID)
            guard !Task.isCancelled, generation == backupPolicySaveGeneration else { return }
            if let backupStore {
                let report = try await backupStore.applyRetentionPolicy(policy, projectID: projectID)
                if let issue = report.issues.first {
                    backupErrorMessage = "설정은 저장했지만 일부 백업을 정리하지 못했습니다: \(issue.reason)"
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == backupPolicySaveGeneration else { return }
            backupErrorMessage = error.localizedDescription
        }
    }
}
