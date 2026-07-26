import SwiftUI

struct ImportReportView: View {
    let report: ImportReport
    let isWorking: Bool
    let onCancel: () -> Void
    let onImport: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("검사 결과") {
                    LabeledContent("작품 이름", value: report.proposedProjectName)
                    LabeledContent("폴더", value: "\(report.directoryCount)개")
                    LabeledContent("파일", value: "\(report.fileCount)개")
                    LabeledContent("TXT 파일", value: "\(report.textFileCount)개")
                }

                if report.issues.isEmpty {
                    Section {
                        Label("가져올 수 있습니다", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    issueSection(
                        title: "치명 오류 \(report.fatalIssues.count)개",
                        issues: report.fatalIssues,
                        color: .red
                    )
                    issueSection(
                        title: "확인할 경고 \(report.warnings.count)개",
                        issues: report.warnings,
                        color: .writerPadWarning
                    )
                }

                Section {
                    Text("원본 폴더는 수정하지 않습니다. 플롯·메인 스토리 틀·레거시 백업은 일반 사용자 폴더로 그대로 보존됩니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Windows 작품 검사")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기", action: onCancel)
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(report.warnings.isEmpty ? "가져오기" : "경고 확인 후 가져오기") {
                        onImport()
                    }
                    .disabled(!report.canImport || isWorking)
                }
            }
            .overlay {
                if isWorking {
                    ProgressView("가져오는 중…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    @ViewBuilder
    private func issueSection(
        title: String,
        issues: [ImportIssue],
        color: Color
    ) -> some View {
        if !issues.isEmpty {
            Section(title) {
                ForEach(issues) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.message)
                        if !issue.relativePath.isEmpty {
                            Text(issue.relativePath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(color)
                }
            }
        }
    }
}
