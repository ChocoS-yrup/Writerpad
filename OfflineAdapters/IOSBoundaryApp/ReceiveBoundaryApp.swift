import SwiftUI
import UniformTypeIdentifiers
import UIKit
// This standalone target compiles the exact local adapter sources directly.

@main
struct ReceiveBoundaryApp: App {
    @StateObject private var controller: IOSBoundaryController
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectingHandoff = false
    private enum ApprovalPresentation { case review, running, result(String) }
    @State private var approvalPresentation: ApprovalPresentation = .review
    @State private var showingApproval = false
    @State private var showingStored=false
    @State private var showingEditable=false
    @State private var showingAuthentication = false
    @State private var loginEmail = ""
    @State private var loginPassword = ""

    // Startup stores an external launch hash only. The explicit configuration button validates
    // fixed local files; neither launch nor the document picker obtains a session or approval.
    init() {
        _controller=StateObject(wrappedValue:IOSBoundaryController(bootstrap:.native(arguments:ProcessInfo.processInfo.arguments)))
    }
    init(configuration:ReceiveAppPreparation.Configuration,pins:ReceiveNativePreparationEvidence.Pins,sessionOwner:ReceiveAuthOwner) {
        let evidence=ReceiveNativePreparationEvidence.native(pins:pins)
        self.init(preparation:evidence.preparation(configuration:configuration,sessionOwner:sessionOwner))
    }
    init(configuration:ReceiveAppPreparation.Configuration,pins:ReceiveNativePreparationEvidence.Pins,authentication:ReceiveDedicatedAuthentication) {
        let evidence=ReceiveNativePreparationEvidence.native(pins:pins)
        let preparation=evidence.preparation(configuration:configuration,sessionOwner:authentication.owner)
        _controller=StateObject(wrappedValue:IOSBoundaryController(preparation:preparation,authentication:authentication))
    }
    init(configuration:ReceiveAppPreparation.Configuration,pins:ReceiveNativePreparationEvidence.Pins,passwordTransport:ReceivePasswordAuthTransport) throws {
        self.init(configuration:configuration,pins:pins,authentication:try passwordTransport.authentication(configuration:configuration))
    }
    init(preparation:ReceiveAppPreparation?) {
        _controller=StateObject(wrappedValue:IOSBoundaryController(preparation:preparation))
    }
    init(prepared:ReceivePreparedApproval?) {
        _controller=StateObject(wrappedValue:IOSBoundaryController(prepared:prepared))
    }

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 20) {
                Text("수신 준비 · 로컬 검증").font(.title2)
                Text(controller.status).multilineTextAlignment(.center)
                if let diagnostic = controller.syntheticFailureDiagnostic {
                    Text("첫 합성 저장 실패 기록 · 앱 종료 전까지 유지")
                        .font(.caption)
                    Text(diagnostic.displayText).font(.caption).textSelection(.enabled)
                }
                Button("합성 저장 확인") {
                    Task { await controller.validateSyntheticStorage() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isRunning || scenePhase != .active)
                Button("보관된 인계 자료 확인") {
                    controller.beginWindowsSelection()
                    selectingHandoff = true
                }
                .disabled(controller.isRunning || scenePhase != .active)
                if let review = controller.windowsReview {
                    Text("대상 \(review.members)개 · 참조 \(review.references)개 · 미확인 증거 \(review.missing_evidence)개")
                        .font(.caption)
                }
                Text("인계 자료는 읽기 전용입니다. 현재 서버 상태 확인이나 수신 적용은 하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("설정 파일 확인") { controller.loadConfiguration() }
                    .disabled(!controller.canLoadConfiguration || controller.isRunning || scenePhase != .active)
                if let diagnostic=controller.configurationFailureDiagnostic {
                    Text("첫 설정 실패 기록 · 앱 종료 전까지 유지").font(.caption)
                    Text(diagnostic).font(.caption).textSelection(.enabled)
                }
                Button("저장된 수신 자료 확인") {
                    Task {await controller.readStoredSnapshot();showingStored=controller.storedSnapshot != nil}
                }
                .disabled(!controller.canReadStored || controller.isRunning || controller.isAuthenticating || scenePhase != .active)
                if !controller.storedReadStatus.isEmpty {Text(controller.storedReadStatus).font(.caption)}
                Text(controller.authenticationStatus).font(.caption)
                Button("전용 계정 로그인") { showingAuthentication=true }
                    .disabled(!controller.authenticationConfigured || controller.isRunning || controller.isAuthenticating || scenePhase != .active)
                if controller.hasDedicatedSession {
                    Button("전용 세션 지우기") { controller.cancelAuthentication() }
                }
                Button("설정·전용 세션 준비") { controller.prepareConfiguredReceive() }
                    .disabled(!controller.canPrepare || controller.isRunning || controller.isAuthenticating || scenePhase != .active)
                Button("준비된 실행 범위 확인") {
                    approvalPresentation = .review
                    controller.showPreparedApproval()
                    showingApproval = controller.approvalReviewText != nil
                }
                .disabled(!controller.approvalConfigured || controller.isRunning || scenePhase != .active)
                if !controller.approvalConfigured {
                    Text("실제 실행 설정 미제공 · 실행 차단")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
            .sheet(isPresented:$selectingHandoff) {
                LocalHandoffPicker { url in
                    selectingHandoff = false
                    if let url { Task { await controller.reviewWindowsFile(url) } }
                }
            }
            .sheet(isPresented:$showingStored,onDismiss:{controller.dismissStoredSnapshot()}) {
                VStack(spacing:16) {
                    Text("저장된 수신 자료 · 읽기 전용").font(.headline)
                    Text("과거 완료한 저장 자료입니다. 현재 서버 조회·편집·송수신은 하지 않습니다.").font(.caption)
                    if let snapshot=controller.storedSnapshot {
                        ScrollView {
                            VStack(alignment:.leading,spacing:20) {
                                Text(snapshot.folderName).font(.headline)
                                ForEach(snapshot.documents) {document in
                                    VStack(alignment:.leading,spacing:8) {
                                        Text(document.name).font(.headline)
                                        if document.byteCount==0 {Text("빈 문서").foregroundStyle(.secondary)}
                                        else {Text(document.text).textSelection(.enabled)}
                                    }
                                }
                            }.frame(maxWidth:.infinity,alignment:.leading)
                        }
                    } else {Text("앱 상태가 변경되어 자료 표시를 닫았습니다. 다시 확인해 주세요.")}
                    Text("편집 사본은 수신 원본과 분리됩니다. 서버 전송·자동 수신은 하지 않습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("편집용 로컬 사본 만들기") {Task {await controller.createEditableCopy()}}
                        .disabled(controller.isRunning || controller.editableCopyReady || scenePhase != .active)
                    Button("기존 로컬 사본 확인") {Task {await controller.reopenEditableCopy()}}
                        .disabled(controller.isRunning || scenePhase != .active)
                    if !controller.editableCopyStatus.isEmpty {Text(controller.editableCopyStatus).font(.caption)}
                    if !controller.editableExportedFileName.isEmpty {
                        Text("최종 파일명: \(controller.editableExportedFileName)").font(.caption)
                    }
                    Button("로컬 편집 열기") {showingEditable=true}
                        .disabled(!controller.editableCopyReady || controller.editableSnapshot == nil || scenePhase != .active)
                    Button("닫기") {showingStored=false}
                }.padding()
                .sheet(isPresented:$showingEditable) {EditableCopyView(controller:controller,isPresented:$showingEditable)}
            }
            .sheet(isPresented:$showingAuthentication,onDismiss:{
                loginEmail="";loginPassword="";controller.dismissAuthentication()
            }) {
                VStack(spacing:16) {
                    Text("전용 계정 로그인").font(.headline)
                    Text("로그인 후 수신 범위를 별도로 확인합니다.").font(.caption)
                    if !controller.authenticationDestination.isEmpty {
                        Text(controller.authenticationDestination).font(.caption).textSelection(.enabled)
                    }
                    TextField("이메일",text:$loginEmail)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    SecureField("비밀번호",text:$loginPassword).privacySensitive()
                    Button("저장된 수신 자료 확인") {
                    Task {await controller.readStoredSnapshot();showingStored=controller.storedSnapshot != nil}
                }
                .disabled(!controller.canReadStored || controller.isRunning || controller.isAuthenticating || scenePhase != .active)
                if !controller.storedReadStatus.isEmpty {Text(controller.storedReadStatus).font(.caption)}
                Text(controller.authenticationStatus).font(.caption)
                    Button("로그인") {
                        controller.signIn(email:loginEmail,password:loginPassword)
                        loginEmail="";loginPassword=""
                    }.disabled(controller.isAuthenticating || loginEmail.isEmpty || loginPassword.isEmpty || scenePhase != .active)
                    Button(controller.hasDedicatedSession ? "닫기":"취소") {
                        if !controller.hasDedicatedSession {controller.cancelAuthentication()}
                        loginEmail="";loginPassword="";showingAuthentication=false
                    }
                }.padding()
                .onDisappear {loginEmail="";loginPassword=""}
            }
            .sheet(isPresented:$showingApproval,onDismiss:{controller.dismissPreparedApproval()}) {
                VStack(spacing:16) {
                    switch approvalPresentation {
                    case .review:
                        ScrollView { Text(controller.approvalReviewText ?? "승인이 취소되었거나 더 이상 유효하지 않습니다")
                            .font(.caption).frame(maxWidth:.infinity,alignment:.leading) }
                        Button("표시된 범위로 1회 실행") {
                            // Consume the displayed ticket once; keep this sheet for the result.
                            guard case .review = approvalPresentation else { return }
                            approvalPresentation = .running
                            Task {
                                await controller.confirmPreparedApproval()
                                approvalPresentation = .result(controller.status)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.approvalReviewText == nil || controller.isRunning || scenePhase != .active)
                        Button("취소") {controller.cancelPreparedApproval();showingApproval=false}
                    case .running:
                        ProgressView("승인된 수신 확인 중")
                        Text("완료될 때까지 앱을 화면에 열어 두세요. 결과는 이 창에 표시됩니다.")
                            .font(.caption)
                        Button("실행 취소") {controller.cancelPreparedApproval();showingApproval=false}
                    case .result(let message):
                        Text(message).frame(maxWidth:.infinity,alignment:.leading)
                        Button("닫기") {showingApproval=false}
                    }
                }.padding()
            }
            .task { controller.setSceneActive(scenePhase == .active) }
            .onChange(of:scenePhase) { _, phase in
                if phase != .active {loginEmail="";loginPassword="";showingAuthentication=false}
                controller.setSceneActive(phase == .active)
            }
        }
    }
}

private struct EditableCopyView: View {
    @ObservedObject var controller:IOSBoundaryController
    @SwiftUI.Binding var isPresented:Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var selected:UUID?
    @State private var drafts=ReceiveEditableDrafts()
    @State private var confirmingClose=false
    @State private var exportReview:ReceiveEditableExportPayload?
    @State private var exportDocument:ReceiveTXTDocument?
    @State private var exportPayload:ReceiveEditableExportPayload?
    @State private var exportStatus=""
    @State private var promotionReview:ReceiveEditablePromotionPackage?
    @State private var promotionDocument:ReceivePromotionDocument?
    @State private var promotionPayload:ReceiveEditablePromotionPackage?
    private var document:ReceiveEditableSnapshot.Document? {
        controller.editableSnapshot?.documents.first{$0.id==selected} ?? controller.editableSnapshot?.documents.first
    }
    var body:some View {
        VStack(spacing:12) {
            Text("로컬 편집 · 서버 전송 없음").font(.headline)
            if let snapshot=controller.editableSnapshot {
                Text("출처: \(snapshot.folderName)").font(.caption).foregroundStyle(.secondary)
                Text("작업 사본 준비됨 · 문서 \(snapshot.documents.count)개 · 마지막 local revision \(snapshot.documents.map(\.revision).max() ?? 0)")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("문서",selection:SwiftUI.Binding(get:{selected ?? snapshot.documents.first!.id},set:{selected=$0})) {
                    ForEach(snapshot.documents){item in Text(item.name).tag(item.id)}
                }
                if let item=document {
                    TextEditor(text:SwiftUI.Binding(get:{drafts.text(for:item)},set:{drafts.set($0,for:item.id)}))
                        .border(.secondary)
                    Text("local revision \(item.revision)").font(.caption).foregroundStyle(.secondary)
                    if drafts.isDirty(item) {Text("저장하지 않은 변경").font(.caption).foregroundStyle(.orange)}
                    Button("저장") {Task{await controller.saveEditableDocument(id:item.id,revision:item.revision,text:drafts.text(for:item))}}
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.isRunning || controller.isAuthenticating || !drafts.isDirty(item))
                    Button("저장된 본문 TXT 내보내기") {
                        do {
                            controller.beginEditableExport()
                            exportReview=try ReceiveEditableExport.prepare(
                                snapshot:snapshot,
                                documentID:item.id,
                                draftText:drafts.text(for:item)
                            )
                            exportStatus=""
                        } catch ReceiveEditableExportError.unsavedDraft {
                            exportStatus="먼저 로컬 저장을 완료하세요"
                        } catch {
                            exportStatus="내보내기 준비를 확인하지 못했습니다"
                        }
                    }
                    .disabled(controller.isRunning || controller.isAuthenticating || drafts.isDirty(item) || scenePhase != .active)
                    if drafts.isDirty(item) {Text("먼저 로컬 저장을 완료하세요").font(.caption).foregroundStyle(.secondary)}
                    Button("WriterPad 로컬 작품 package 내보내기") {
                        Task {
                            controller.beginEditableExport()
                            promotionReview=await controller.prepareEditablePromotion(
                                draftTexts:drafts.all(in:snapshot)
                            )
                        }
                    }
                    .disabled(
                        controller.isRunning || controller.isAuthenticating
                            || drafts.dirtyCount(in:snapshot)>0 || scenePhase != .active
                    )
                }
            } else {Text("앱 상태가 변경되어 편집을 닫았습니다.")}
            if !exportStatus.isEmpty {Text(exportStatus).font(.caption)}
            if !controller.editableCopyStatus.isEmpty {Text(controller.editableCopyStatus).font(.caption)}
            if !controller.editableExportedFileName.isEmpty {
                Text("최종 파일명: \(controller.editableExportedFileName)").font(.caption)
            }
            Button("닫기") {
                if let snapshot=controller.editableSnapshot,drafts.dirtyCount(in:snapshot)>0 {confirmingClose=true}
                else {isPresented=false}
            }
        }
        .padding()
        .onAppear {
            if let snapshot=controller.editableSnapshot {
                drafts=ReceiveEditableDrafts(snapshot:snapshot)
                selected=snapshot.documents.first?.id
            }
        }
        .sheet(item:$exportReview) {payload in
            VStack(spacing:16) {
                Text("저장된 본문 내보내기").font(.headline)
                Text("본문 TXT 한 개만 내보냅니다. 원본·작업 사본·서버 상태는 변경하지 않습니다.")
                    .font(.caption).multilineTextAlignment(.center)
                VStack(alignment:.leading,spacing:8) {
                    Text("파일명: \(payload.fileName)")
                    Text("local revision: \(payload.revision)")
                    Text("크기: \(payload.bytes.count) bytes")
                    Text("SHA-256: \(payload.sha256)").textSelection(.enabled)
                }.font(.caption).frame(maxWidth:.infinity,alignment:.leading)
                Text("오프라인 보관이 목적이면 파일 화면에서 ‘나의 iPad’를 선택하세요.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("파일 위치 선택") {
                    exportPayload=payload
                    exportDocument=ReceiveTXTDocument(bytes:payload.bytes)
                    exportReview=nil
                    DispatchQueue.main.async{isExporting=true}
                }.buttonStyle(.borderedProminent)
                Button("취소",role:.cancel) {exportReview=nil;exportStatus="내보내기를 취소했습니다"}
            }.padding()
        }
        .sheet(item:$promotionReview) {package in
            VStack(spacing:16) {
                Text("WriterPad 로컬 작품 package").font(.headline)
                Text("저장된 편집 사본만 포함합니다. Receive Boundary 원본·작업 사본과 서버 상태는 변경하지 않습니다.")
                    .font(.caption).multilineTextAlignment(.center)
                VStack(alignment:.leading,spacing:8) {
                    Text("파일명: \(package.fileName)")
                    Text("문서: \(package.review.documents.count)개")
                    Text("본문: \(package.review.documents.reduce(0){$0+$1.byteCount}) bytes")
                    Text("package SHA-256: \(package.review.fingerprint)").textSelection(.enabled)
                }.font(.caption).frame(maxWidth:.infinity,alignment:.leading)
                Text("WriterPad에서 다시 검사한 뒤 사용자가 확정해야 새 로컬 작품이 생성됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("파일 위치 선택") {
                    do {
                        promotionPayload=package
                        promotionDocument=try ReceivePromotionDocument(package:package)
                        promotionReview=nil
                        DispatchQueue.main.async{isExportingPromotion=true}
                    } catch {
                        promotionReview=nil
                        exportStatus="package 파일 구성을 만들지 못했습니다"
                    }
                }.buttonStyle(.borderedProminent)
                Button("취소",role:.cancel) {
                    promotionReview=nil;exportStatus="package 내보내기를 취소했습니다"
                }
            }.padding()
        }
        .fileExporter(
            isPresented:$isExporting,
            document:exportDocument,
            contentType:.plainText,
            defaultFilename:exportPayload?.fileName ?? "본문.txt"
        ) {result in
            exportDocument=nil
            switch result {
            case .success(let url):
                guard let payload=exportPayload else {
                    exportStatus="파일 저장 결과를 재검증하지 못했습니다";return
                }
                controller.completeEditableExport(payload,at:url)
                exportPayload=nil
            case .failure(let error):
                exportPayload=nil
                if (error as NSError).code == NSUserCancelledError {
                    exportStatus="내보내기를 취소했습니다"
                } else {exportStatus="파일 저장 결과를 재검증하지 못했습니다"}
            }
        }
        .fileExporter(
            isPresented:$isExportingPromotion,
            document:promotionDocument,
            contentType:.writerPadReceivePromotion,
            defaultFilename:promotionPayload?.fileName ?? "WriterPad-수신편집본.writerpadpromotion"
        ) {result in
            promotionDocument=nil
            switch result {
            case .success(let url):
                guard let package=promotionPayload else {
                    exportStatus="package 저장 결과를 확인하지 못했습니다";return
                }
                controller.completeEditablePromotionExport(package,at:url)
                promotionPayload=nil
            case .failure(let error):
                promotionPayload=nil
                exportStatus=(error as NSError).code == NSUserCancelledError
                    ? "package 내보내기를 취소했습니다"
                    : "package 저장 결과를 확인하지 못했습니다"
            }
        }
        .alert("저장하지 않은 변경을 버릴까요?",isPresented:$confirmingClose) {
            Button("계속 편집",role:.cancel) {}
            Button("변경 버리고 닫기",role:.destructive) {isPresented=false}
        } message: {Text("저장하지 않은 문서의 변경은 작업 사본에 기록되지 않습니다.")}
    }

    @State private var isExporting=false
    @State private var isExportingPromotion=false
}

private extension UTType {
    static let writerPadReceivePromotion = UTType(
        exportedAs:"com.chocos.writerpad.receive-promotion",
        conformingTo:.package
    )
}

private struct ReceivePromotionDocument:FileDocument {
    static var readableContentTypes:[UTType]{[.writerPadReceivePromotion]}
    let package:ReceiveEditablePromotionPackage
    init(package:ReceiveEditablePromotionPackage)throws{
        _=try package.fileWrapper();self.package=package
    }
    init(configuration:ReadConfiguration)throws{throw CocoaError(.fileReadCorruptFile)}
    func fileWrapper(configuration:WriteConfiguration)throws->FileWrapper{try package.fileWrapper()}
}

private struct ReceiveTXTDocument:FileDocument {
    static var readableContentTypes:[UTType]{[.plainText]}
    let bytes:Data
    init(bytes:Data){self.bytes=bytes}
    init(configuration:ReadConfiguration)throws{throw CocoaError(.fileReadCorruptFile)}
    func fileWrapper(configuration:WriteConfiguration)throws->FileWrapper {
        FileWrapper(regularFileWithContents:bytes)
    }
}

/// Explicit open-in-place selection: no automatic app-owned import copy is requested.
private struct LocalHandoffPicker: UIViewControllerRepresentable {
    let selected: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected:selected) }
    func makeUIViewController(context:Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes:[.json],asCopy:false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller:UIDocumentPickerViewController,context:Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let selected: (URL?) -> Void
        init(selected:@escaping (URL?) -> Void) { self.selected = selected }
        func documentPicker(_ controller:UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]) { selected(urls.first) }
        func documentPickerWasCancelled(_ controller:UIDocumentPickerViewController) { selected(nil) }
    }
}
