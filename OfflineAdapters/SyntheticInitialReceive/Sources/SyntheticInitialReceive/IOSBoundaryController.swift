#if os(iOS)
import Foundation
import UIKit
import Combine

@MainActor
public final class IOSBoundaryController: ObservableObject {
    @Published public private(set) var status = "대기 중"
    @Published public private(set) var isRunning = false
    @Published public private(set) var syntheticReady = false
    @Published public private(set) var syntheticFailureDiagnostic: StorageFailureDiagnostic?
    @Published public private(set) var syntheticJournalReady = false
    @Published public private(set) var windowsReview: WindowsHandoffReview?
    @Published public private(set) var approvalConfigured = false
    @Published public private(set) var approvalReviewText: String?
    private var approvalCallSite: ReceiveApprovalCallSite?
    private var approvalReview: ReceiveApprovalReview?
    private var appPreparation:ReceiveAppPreparation?
    private var bootstrap:ReceiveConfigurationBootstrap?
    @Published public private(set) var storedSnapshot:ReceiveStoredSnapshot?
    @Published public private(set) var storedReadStatus=""
    @Published public private(set) var canReadStored=false
    private var storedReader:((BoundaryLease)throws->ReceiveStoredSnapshot)?
    private var storedLocal:UUID?
    @Published public private(set) var editableCopyReady=false
    @Published public private(set) var editableCopyStatus=""
    @Published public private(set) var editableSnapshot:ReceiveEditableSnapshot?
    @Published public private(set) var editableExportedFileName=""
    private var pendingEditableExport:(payload:ReceiveEditableExportPayload,url:URL)?
    private var postLoginPreparation:ReceivePostLoginPreparation?
    private var bootstrapLoginUsed=false
    @Published public private(set) var canLoadConfiguration=false
    @Published public private(set) var configurationFailureDiagnostic:String?
    convenience init(bootstrap:ReceiveConfigurationBootstrap) {
        self.init(prepared:nil);self.bootstrap=bootstrap;canLoadConfiguration=true
    }
    public func loadConfiguration() {
        guard !isRunning,sceneActive,protectedAvailable,let bootstrap else {return}
        self.bootstrap=nil;canLoadConfiguration=false
        do {
            let (envelope,target)=try bootstrap.load()
            let evidence=ReceiveNativePreparationEvidence.native(pins:.init(installationSHA256:envelope.installationSHA256,localSHA256:envelope.localSHA256))
            try connectionNeed(evidence.readInstallation()==envelope.identity,.unverified)
            storedLocal = try evidence.readLocal().local
            storedReader={lease in
                try lease.check()
                try connectionNeed(evidence.readInstallation()==envelope.identity,.unverified)
                let local=try evidence.readLocal()
                let result=try ReceiveStoredReader.read(home:BoundarySystemHome.resolve(),local:local.local,target:target,check:{try lease.check()})
                try connectionNeed(evidence.readInstallation()==envelope.identity && evidence.readLocal()==local,.unverified)
                return result
            }
            canReadStored=true
            let account=UUID(uuidString:try target.binding.str("account_id"))!
            let endpoint=try target.binding.str("endpoint")
            let transport=try ReceivePasswordAuthTransport.live(target:.init(origin:URL(string:endpoint)!,account:account,publishableKey:envelope.publishableKey))
            let auth=ReceiveDedicatedAuthentication(account:account,destination:endpoint,authenticate:{try await transport.signIn($0)})
            postLoginPreparation=ReceivePostLoginPreparation(envelope:envelope,target:target,evidence:evidence,owner:auth.owner)
            bindAuthentication(auth);canPrepare=true
            status="설정 확인 완료 · 로그인은 별도 버튼으로 시작하세요"
        } catch {
            if configurationFailureDiagnostic == nil {
                let failure = error as? ReceiveConfigurationFailure ?? .init(stage:.composition,code:"unverified")
                configurationFailureDiagnostic=failure.description
            }
            status="설정 확인 차단 · 아래 진단 코드를 확인하세요"
        }
    }
    public func readStoredSnapshot() async {
        guard !isRunning,!isAuthenticating,sceneActive,protectedAvailable,let reader=storedReader else{return}
        storedSnapshot=nil;storedReadStatus="저장 자료 확인 중";isRunning=true
        defer{isRunning=false}
        do {
            let lease=try lifecycle.begin()
            let snapshot=try await Task.detached {try reader(lease)}.value
            try Task.checkCancellation();try lease.check()
            storedSnapshot=snapshot;storedReadStatus="저장 자료 확인 완료 · 읽기 전용"
        } catch {storedReadStatus="저장 자료 확인 차단 · 완료 기록과 저장 파일을 확인하세요"}
    }
    public func dismissStoredSnapshot() {storedSnapshot=nil}
    public func createEditableCopy() async {
        guard !isRunning,!isAuthenticating,sceneActive,protectedAvailable,
              let snapshot=storedSnapshot,let local=storedLocal else{return}
        editableCopyReady=false;editableSnapshot=nil;editableCopyStatus="편집용 로컬 사본 생성 중";isRunning=true
        defer{isRunning=false}
        do {
            let lease=try lifecycle.begin(),home=try BoundarySystemHome.resolve()
            _ = try await Task.detached {try ReceiveEditableCopy.create(home:home,local:local,snapshot:snapshot,check:{try lease.check()})}.value
            let editable=try await Task.detached {try ReceiveEditableCopy.open(home:home,local:local,snapshot:snapshot,check:{try lease.check()})}.value
            try Task.checkCancellation();try lease.check()
            editableSnapshot=editable;editableCopyReady=true;editableCopyStatus="편집용 로컬 사본 준비 완료 · 서버 전송 없음"
        } catch {editableCopyStatus="편집용 로컬 사본 생성 차단 · 기존 사본은 변경되지 않았습니다"}
    }
    public func reopenEditableCopy() async {
        guard !isRunning,!isAuthenticating,sceneActive,protectedAvailable,
              let snapshot=storedSnapshot,let local=storedLocal else{return}
        editableCopyReady=false;editableSnapshot=nil;editableCopyStatus="기존 로컬 사본 확인 중";isRunning=true
        defer{isRunning=false}
        do {
            let lease=try lifecycle.begin(),home=try BoundarySystemHome.resolve()
            let editable=try await Task.detached {try ReceiveEditableCopy.open(home:home,local:local,snapshot:snapshot,check:{try lease.check()})}.value
            try Task.checkCancellation();try lease.check()
            editableSnapshot=editable;editableCopyReady=true;editableCopyStatus="기존 로컬 사본 확인 완료 · 서버 전송 없음"
        } catch {editableCopyStatus="기존 로컬 사본 확인 차단 · 파일을 변경하지 않았습니다"}
    }
    public func saveEditableDocument(id:UUID,revision:Int,text:String) async {
        guard !isRunning,!isAuthenticating,sceneActive,protectedAvailable,let local=storedLocal,let source=storedSnapshot,editableSnapshot?.sourceRun==source.runID else{return}
        isRunning=true;editableCopyStatus="로컬 저장 중";defer{isRunning=false}
        do {
            let lease=try lifecycle.begin(),home=try BoundarySystemHome.resolve()
            let updated=try await Task.detached {try ReceiveEditableCopy.save(home:home,local:local,snapshot:source,documentID:id,expectedRevision:revision,text:text,check:{try lease.check()})}.value
            try lease.check();editableSnapshot=updated;editableCopyStatus="로컬 저장 완료 · 서버 전송 없음"
        } catch {editableCopyStatus=ReceiveEditableStatus.saveFailure(error)}
    }

    func prepareEditablePromotion(
        draftTexts: [UUID:String]
    ) async -> ReceiveEditablePromotionPackage? {
        guard !isRunning,!isAuthenticating,sceneActive,protectedAvailable,
              let reader=storedReader,let local=storedLocal else{return nil}
        isRunning=true;editableCopyStatus="WriterPad 로컬 작품 package 준비 중"
        defer{isRunning=false}
        do {
            let lease=try lifecycle.begin(),home=try BoundarySystemHome.resolve()
            let result=try await Task.detached(priority:.utility) {
                let source=try reader(lease)
                let input=try ReceiveEditableCopy.promotionInput(
                    home:home,local:local,snapshot:source,check:{try lease.check()}
                )
                let package=try ReceiveEditablePromotion.prepare(
                    input:input,draftTexts:draftTexts
                )
                try lease.check()
                return (source,input.editable,package)
            }.value
            try Task.checkCancellation();try lease.check()
            storedSnapshot=result.0;editableSnapshot=result.1;editableCopyReady=true
            editableCopyStatus="package 검토 준비 완료 · 서버 전송 없음"
            return result.2
        } catch ReceiveEditablePromotionError.unsavedDraft {
            editableCopyStatus="package 준비 차단 · 먼저 로컬 저장을 완료하세요"
        } catch {
            editableCopyStatus="package 준비 차단 · 원본과 작업 사본을 다시 확인하세요"
        }
        return nil
    }

    func completeEditablePromotionExport(
        _:ReceiveEditablePromotionPackage,
        at url:URL
    ) {
        editableExportedFileName=url.lastPathComponent
        editableCopyStatus="WriterPad package 저장 완료 · 앱 내부 자료 변경 없음"
    }

    func beginEditableExport() {editableExportedFileName=""}

    func completeEditableExport(_ payload:ReceiveEditableExportPayload,at url:URL) {
        pendingEditableExport=(payload,url)
        if sceneActive {Task{await verifyPendingEditableExport()}}
    }

    private func verifyPendingEditableExport() async {
        guard sceneActive,let pending=pendingEditableExport else{return}
        pendingEditableExport=nil
        await verifyEditableExport(pending.payload,at:pending.url)
    }

    func verifyEditableExport(_ payload:ReceiveEditableExportPayload,at url:URL) async {
        editableExportedFileName=""
        guard !isRunning,!isAuthenticating,sceneActive,protectedAvailable,
              let reader=storedReader,let local=storedLocal else {
            editableCopyStatus="파일 저장 결과를 재검증하지 못했습니다"
            return
        }
        isRunning=true;editableCopyStatus="내보낸 파일과 작업 사본 확인 중"
        defer{isRunning=false}
        do {
            let lease=try lifecycle.begin(),home=try BoundarySystemHome.resolve()
            let result=try await Task.detached(priority:.utility) {
                let scoped=url.startAccessingSecurityScopedResource()
                defer{if scoped{url.stopAccessingSecurityScopedResource()}}
                try lease.check()
                let handle=try FileHandle(forReadingFrom:url)
                defer{try? handle.close()}
                let external=try handle.read(upToCount:payload.bytes.count+1) ?? Data()
                try payload.verifyExternal(external)
                let source=try reader(lease)
                let editable=try ReceiveEditableCopy.open(home:home,local:local,snapshot:source,check:{try lease.check()})
                try payload.verifyCurrent(editable)
                try lease.check()
                return (source,editable)
            }.value
            try Task.checkCancellation();try lease.check()
            storedSnapshot=result.0;editableSnapshot=result.1;editableCopyReady=true
            editableExportedFileName=url.lastPathComponent
            editableCopyStatus="내보내기 완료 · 원본과 작업 사본 변경 없음"
        } catch ReceiveEditableExportError.workspaceChanged {
            editableCopyReady=false;editableSnapshot=nil
            editableCopyStatus="내보내기 확인 차단 · 작업 사본이 변경됐습니다"
        } catch {
            editableCopyReady=false;editableSnapshot=nil
            editableCopyStatus="파일 저장 결과를 재검증하지 못했습니다"
        }
    }

    @Published public private(set) var canPrepare = false
    private var authentication:ReceiveDedicatedAuthentication?
    @Published public private(set) var authenticationDestination=""
    @Published public private(set) var authenticationConfigured=false
    @Published public private(set) var isAuthenticating=false
    @Published public private(set) var hasDedicatedSession=false
    @Published public private(set) var authenticationStatus="인증 공급자 미제공"
    private var launchPreparation: ReceivePreparedApproval?
    public let baselineApplied = false
    public let executionAllowed = false
    private let lifecycle = BoundaryLifecycle()
    private lazy var nativeSession = ReceiveOfflineAppSession(lifecycle:lifecycle)
    private var tokens: [NSObjectProtocol] = []
    private var sceneActive = false
    private var protectedAvailable = false

    public convenience init() {self.init(prepared:nil)}

    convenience init(preparation:ReceiveAppPreparation?) {
        self.init(prepared:nil)
        appPreparation=preparation;canPrepare=preparation != nil
    }
    convenience init(preparation:ReceiveAppPreparation?,authentication:ReceiveDedicatedAuthentication) {
        self.init(preparation:preparation)
        bindAuthentication(authentication)
    }
    private func bindAuthentication(_ authentication:ReceiveDedicatedAuthentication) {
        self.authentication=authentication
        authenticationConfigured=authentication.isConfigured
        authenticationDestination=authentication.destination ?? ""
        authentication.onInvalidate={ [weak self] in self?.cancelPreparedApproval() }
        authentication.onStateChange={ [weak self] state in self?.updateAuthentication(state) }
        updateAuthentication(authentication.state)
    }
    private func updateAuthentication(_ state:ReceiveDedicatedAuthentication.State) {
        isAuthenticating=state == .authenticating;hasDedicatedSession=state == .signedIn
        switch state {
        case .unavailable:authenticationStatus="인증 공급자 미제공"
        case .signedOut:authenticationStatus="전용 세션 없음"
        case .authenticating:authenticationStatus="인증 중"
        case .signedIn:authenticationStatus="전용 세션 준비됨 · 수신은 별도 확인 필요"
        case .failed:authenticationStatus="인증 실패 · 전용 세션 없음"
        }
    }
    public func signIn(email:String,password:String) {
        guard !isRunning,sceneActive,protectedAvailable,let authentication else {return}
        if postLoginPreparation != nil {
            guard !bootstrapLoginUsed else {authenticationStatus="이 설정의 로그인 시도는 이미 사용되었습니다";return}
            bootstrapLoginUsed=true
        }
        do {try authentication.signIn(.init(email:email,password:password))}
        catch {authenticationStatus="인증을 시작할 수 없습니다"}
    }
    public func cancelAuthentication() {authentication?.cancel()}
    public func dismissAuthentication() {if isAuthenticating {authentication?.cancel()}}
    public func prepareConfiguredReceive() {
        guard !isRunning,!isAuthenticating,hasDedicatedSession || appPreparation != nil,sceneActive,protectedAvailable,canPrepare else {return}
        canPrepare=false
        do {
            let preparation:ReceiveAppPreparation
            if let factory=postLoginPreparation {preparation=try factory.preparation()}
            else if let supplied=appPreparation {preparation=supplied}
            else {throw ReceiveConnectionError.closed}
            appPreparation=nil
            try installPreparedApproval(preparation.prepare())
            status="설정·전용 세션 확인 완료 · 실행 범위를 확인하세요"
        } catch {
            cancelPreparedApproval()
            status="준비 차단 · 설정·설치 식별·전용 세션을 다시 준비하세요"
        }
    }

    // Composition injection stores a prepared descriptor only, without consulting any provider.
    init(prepared:ReceivePreparedApproval?) {
        launchPreparation=prepared
        // Initialization observes lifecycle only; no identity, container or store is opened.
        protectedAvailable = UIApplication.shared.isProtectedDataAvailable
        lifecycle.update(active:false,protectedDataAvailable:protectedAvailable)
        observe(UIApplication.willResignActiveNotification) { $0.setSceneActive(false) }
        observe(UIApplication.didEnterBackgroundNotification) { $0.setSceneActive(false) }
        observe(UIApplication.willTerminateNotification) { $0.setSceneActive(false) }
        observe(UIApplication.protectedDataWillBecomeUnavailableNotification) { controller in
            controller.protectedAvailable = false; controller.revoke()
        }
        observe(UIApplication.protectedDataDidBecomeAvailableNotification) { controller in
            controller.protectedAvailable = UIApplication.shared.isProtectedDataAvailable; controller.revoke()
        }
    }

    private func observe(_ name: Notification.Name, action: @escaping @MainActor (IOSBoundaryController) -> Void) {
        tokens.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { if let self = self { action(self) } }
        })
    }
    deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }

    public func setSceneActive(_ active: Bool) {
        sceneActive = active
        protectedAvailable = UIApplication.shared.isProtectedDataAvailable
        revoke()
        if active,protectedAvailable,let preparation=launchPreparation {
            launchPreparation=nil
            do {try installPreparedApproval(preparation)}
            catch {status="실행 준비 미완료 · 설정은 활성화되지 않았습니다"}
        }
        if active,pendingEditableExport != nil {Task{await verifyPendingEditableExport()}}
    }
    private func revoke() {
        storedSnapshot=nil
        editableCopyReady=false;editableCopyStatus="";editableSnapshot=nil;editableExportedFileName=""
        authentication?.cancel()
        approvalCallSite?.cancel();approvalCallSite=nil;approvalReview=nil
        approvalConfigured=false;approvalReviewText=nil
        lifecycle.update(active:sceneActive,protectedDataAvailable:protectedAvailable)
        nativeSession.invalidate()
        syntheticReady = false
        syntheticJournalReady = false
        windowsReview = nil
        status = sceneActive && protectedAvailable ? "대기 중 · 직접 검증을 시작하세요" : "중단됨 · 앱 활성화와 잠금 해제 필요"
    }

    // Trusted composition only. This is never called by the Windows file picker or on launch.
    // Stage-two preparation supplies exact device/install/config/cache providers after its approval.
    func installPreparedApproval(_ preparation: ReceivePreparedApproval) throws {
        guard !isRunning,sceneActive,protectedAvailable else {throw ReceiveConnectionError.closed}
        approvalCallSite?.cancel()
        approvalCallSite=ReceiveApprovalCallSite(prepared:preparation)
        approvalReview=nil;approvalReviewText=nil;approvalConfigured=true
    }

    public func showPreparedApproval() {
        guard !isRunning else {return}
        do {
            _ = try lifecycle.begin()
            guard let site=approvalCallSite else {throw ReceiveConnectionError.closed}
            let review=try site.present();approvalReview=review;approvalReviewText=review.text
        } catch {cancelPreparedApproval();status="실행 준비 미완료 · 승인할 설정이 없습니다"}
    }

    public func cancelPreparedApproval() {
        approvalCallSite?.cancel();approvalReview=nil;approvalReviewText=nil;approvalConfigured=false
    }

    public func dismissPreparedApproval() {
        // Dismissal after completion has no effect; swiping away a pending/running sheet cancels it.
        if approvalReview != nil || isRunning {cancelPreparedApproval()}
    }

    public func confirmPreparedApproval() async {
        guard !isRunning,let site=approvalCallSite,let review=approvalReview else {return}
        approvalReview=nil;approvalReviewText=nil;approvalConfigured=false
        isRunning=true;syntheticReady=false;status="승인된 수신 확인 중"
        defer {isRunning=false}
        await nativeSession.run {lease in
            guard Bundle.main.bundleIdentifier==ProtectedBoundaryContainer.bundleID else {throw ReceiveConnectionError.closed}
            return try site.confirm(review,lease:lease,protection:.completeProtection(lease:lease))
        }
        status=nativeSession.state == .complete ? "승인 범위 확인 완료 · 편집·자동 송수신은 닫혀 있습니다" : "중단됨 · 실행·저장 자료는 유지됩니다"
    }

    public func beginWindowsSelection() {
        guard !isRunning else { return }
        windowsReview = nil
        status = "기기에 보관한 인계 파일을 선택하세요"
    }

    public func reviewWindowsFile(_ url: URL) async {
        guard !isRunning else { return }
        windowsReview = nil
        do {
            guard Bundle.main.bundleIdentifier == ProtectedBoundaryContainer.bundleID else { throw LocalBoundaryError.bundle }
            let lease = try lifecycle.begin()
            let work = WindowsReaderWork(lease:lease)
            // External pin comes from the retained record, never from the selected payload.
            let expected = try WindowsHandoffExpectation.retainedSeptember14()
            isRunning = true; status = "인계 자료 확인 중"
            defer { isRunning = false }
            let result = try await Task.detached(priority:.utility) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try Task.checkCancellation()
                let bytes = try work.readLocalFile(url)
                let reviewed = try work.review(portable:bytes,expected:expected)
                try Task.checkCancellation()
                return reviewed
            }.value
            windowsReview = try work.publish(result)
            status = "보관 자료 대조 완료 · 적용은 차단되어 있습니다"
        } catch {
            windowsReview = nil
            // Never show the URL, raw body, account details or underlying error text.
            status = "확인 중단 · 원본은 변경되지 않았습니다"
        }
    }

    // Explicit callable route only; fixed synthetic Auth/URLProtocol, no startup action or new UI trigger.
    public func validateSyntheticJournal() async {
        guard !isRunning else { return }
        syntheticJournalReady = false
        do {
            guard Bundle.main.bundleIdentifier == ProtectedBoundaryContainer.bundleID else { throw LocalBoundaryError.bundle }
            try Task.checkCancellation()
            isRunning = true; status = "합성 실행 기록 확인 중"
            defer { isRunning = false }
            await nativeSession.run { lease in
                let home = URL(fileURLWithPath:NSHomeDirectory(),isDirectory:true).resolvingSymlinksInPath()
                return try ReceiveOfflineAppJob(home:home,declaredBundle:ProtectedBoundaryContainer.bundleID,lease:lease,protection:.completeProtection(lease:lease))
            }
            try Task.checkCancellation()
            syntheticJournalReady = nativeSession.syntheticReady
            status = syntheticJournalReady ? "합성 실행 기록 확인 완료 · 실제 적용은 차단되어 있습니다" : "중단됨 · 실행 기록은 유지됩니다"
        } catch {
            syntheticJournalReady = false
            status = "중단됨 · 실행 기록은 유지됩니다"
        }
    }

    // Internal synthetic-only injection. Never connected to selected Windows files or startup.
    func validateReviewedSyntheticJournal(execution:ReceiveReviewedExecution,owner:ReceiveAuthOwner,clock:ABRuntimeClock,protocolClass:AnyClass) async {
        guard !isRunning else {return}
        isRunning = true;syntheticJournalReady = false;status = "합성 실행 기록 확인 중"
        defer {isRunning = false}
        await nativeSession.run {lease in
            let home = URL(fileURLWithPath:NSHomeDirectory(),isDirectory:true).resolvingSymlinksInPath()
            return try ReceiveReviewedOfflineAppJob(execution:execution,home:home,declaredBundle:Bundle.main.bundleIdentifier ?? "",lease:lease,protection:.completeProtection(lease:lease),owner:owner,clock:clock,protocolClass:protocolClass)
        }
        syntheticJournalReady = nativeSession.syntheticReady
        status = syntheticJournalReady ? "합성 실행 기록 확인 완료 · 실제 적용은 차단되어 있습니다" : "중단됨 · 실행 기록은 유지됩니다"
    }

    // Explicit internal test entry; the descriptor accepts only a disposable temporary namespace.
    func validateOfflineAdmission(execution:ReceiveReviewedExecution,descriptor:ReceiveLocalStoreDescriptor,owner:ReceiveAuthOwner,clock:ABRuntimeClock,protocolClass:AnyClass) async {
        guard !isRunning else { return }
        isRunning = true; syntheticReady = false
        defer { isRunning = false }
        await nativeSession.run { lease in
            guard Bundle.main.bundleIdentifier == ProtectedBoundaryContainer.bundleID else { throw LocalBoundaryError.bundle }
            let home = URL(fileURLWithPath:NSHomeDirectory(),isDirectory:true).resolvingSymlinksInPath()
            return try ReceiveAdmittedOfflineAppJob(execution:execution,descriptor:descriptor,home:home,lease:lease,protection:.completeProtection(lease:lease),owner:owner,clock:clock,protocolClass:protocolClass)
        }
        syntheticReady = nativeSession.syntheticReady
        status = syntheticReady ? "합성 수신·저장 확인 완료 · 실제 적용은 차단되어 있습니다" : "중단됨 · 저장 자료는 유지됩니다"
    }

    // Dormant injection point. No file importer, launch hook, session restoration or SDK startup calls it.
    func validateDedicatedFormats(execution:ReceiveReviewedExecution,paths:ReceiveDedicatedPaths,executionJournalHome:URL,
                                  authority:ReceiveActivationAuthority?,source:ReceiveSessionSource,clock:ABRuntimeClock,
                                  verifyIdentity:@escaping ()throws->Void,protocolClass:AnyClass) async {
        guard !isRunning else{return}
        isRunning=true;syntheticReady=false;defer{isRunning=false}
        await nativeSession.run{lease in
            guard Bundle.main.bundleIdentifier==ProtectedBoundaryContainer.bundleID else{throw LocalBoundaryError.bundle}
            let env=ReceiveDedicatedEnvironment(paths:paths,local:UUID(uuidString:execution.journalBinding.localProjectID)!,bundle:Bundle.main.bundleIdentifier!,source:source,authority:authority,clock:clock,lease:lease,protection:.completeProtection(lease:lease),verifyIdentity:verifyIdentity)
            return try ReceiveDedicatedOfflineAppJob(execution:execution,environment:env,executionJournalHome:executionJournalHome,protocolClass:protocolClass)
        }
        syntheticReady=nativeSession.syntheticReady
        status=syntheticReady ? "전용 저장 형식 확인 완료 · 실제 적용은 차단되어 있습니다" : "중단됨 · 저장 자료는 유지됩니다"
    }

    // Explicit candidate entry only. The app has no default grant issuer or control invoking this.
    func runAuthorizedCandidate(target:ReviewedReceiveTarget,paths:ReceiveDedicatedPaths,journalRoot:URL,
                                authority:ReceiveActivationAuthority?,httpTarget:ReceiveHTTPTarget,source:ReceiveSessionSource,
                                clock:ABRuntimeClock,verifyIdentity:@escaping ()throws->Void,offlineProtocol:AnyClass?=nil) async {
        guard !isRunning else{return}
        isRunning=true;syntheticReady=false;defer{isRunning=false}
        await nativeSession.run{lease in
            guard let authority,Bundle.main.bundleIdentifier==ProtectedBoundaryContainer.bundleID else{throw ReceiveConnectionError.closed}
            let environment=ReceiveDedicatedEnvironment(paths:paths,local:UUID(uuidString:authority.binding.localProjectID)!,bundle:Bundle.main.bundleIdentifier!,source:source,authority:authority,clock:clock,lease:lease,protection:.completeProtection(lease:lease),verifyIdentity:verifyIdentity)
            return try ReceiveAuthorizedRun(environment:environment,target:target,httpTarget:httpTarget,journalRoot:journalRoot,offlineProtocol:offlineProtocol)
        }
        syntheticReady=authority?.rehearsal==true && nativeSession.syntheticReady
        status=nativeSession.syntheticReady ? "지정 수신 확인 완료 · 편집·자동 송수신은 닫혀 있습니다" : "중단됨 · 실행·저장 자료는 유지됩니다"
    }

    public func validateSyntheticStorage() async {
        guard !isRunning else { return }
        syntheticReady = false
        let diagnostic = StorageFailureRecorder()
        do {
            let lease = try StorageDiagnostics.$recorder.withValue(diagnostic) {
                try StorageDiagnostics.at(.entry) {
                    guard Bundle.main.bundleIdentifier == ProtectedBoundaryContainer.bundleID else { throw LocalBoundaryError.bundle }
                    return try lifecycle.begin()
                }
            }
            let home = try StorageDiagnostics.$recorder.withValue(diagnostic) {
                try StorageDiagnostics.at(.container) { try BoundarySystemHome.resolve() }
            }
            isRunning = true; status = "합성 저장 확인 중"
            defer { isRunning = false }
            // Detached tasks do not inherit task locals. Bind this call's recorder explicitly.
            let result = try await Task.detached(priority:.utility) {
                try StorageDiagnostics.$recorder.withValue(diagnostic) {
                    let verify: (URL) throws -> Void = { url in
                        try StorageDiagnostics.at(.protectionRead) {
                            try lease.check(); try SafeFiles.checked(url)
                            let attrs = try FileManager.default.attributesOfItem(atPath:url.path)
                            try CompleteFileProtection.require(attrs[.protectionKey])
                        }
                    }
                    let access = PhysicalStorageAccess(check:lease.check,created:{ url in
                        try StorageDiagnostics.at(.protectionSet) {
                            try lease.check()
                            try FileManager.default.setAttributes([.protectionKey:FileProtectionType.complete],ofItemAtPath:url.path)
                            try verify(url)
                        }
                    },verify:verify)
                    return try SyntheticStorageDiagnosticWork.run(home:home,bundle:ProtectedBoundaryContainer.bundleID,access:access)
                }
            }.value
            try StorageDiagnostics.$recorder.withValue(diagnostic) {
                try StorageDiagnostics.at(.publish) { try lease.check() }
            }
            syntheticReady = result.synthetic_boundary_ready
            status = "합성 저장 확인 완료"
        } catch {
            syntheticReady = false
            // Preserve the first failure across lifecycle changes and later button invocations.
            diagnostic.capture(error,stage:.entry)
            if syntheticFailureDiagnostic == nil { syntheticFailureDiagnostic = diagnostic.failure }
            status = "중단됨 · 저장 자료는 유지됩니다"
        }
    }
}
#endif
