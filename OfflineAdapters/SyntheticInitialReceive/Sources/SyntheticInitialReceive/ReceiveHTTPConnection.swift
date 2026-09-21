import Foundation

struct ReceiveHTTPTarget {
    let origin: URL, account: UUID, project: UUID
    private let key: String
    init(origin:URL,account:UUID,project:UUID,publishableKey:String) throws {
        guard let c = URLComponents(url:origin,resolvingAgainstBaseURL:false) else { throw ReceiveConnectionError.invalidTarget }
        try connectionNeed(c.scheme == "https" && c.host != nil && c.user == nil && c.password == nil && c.port == nil && (c.path.isEmpty || c.path == "/") && c.query == nil && c.fragment == nil,.invalidTarget)
        try connectionNeed(publishableKey.hasPrefix("sb_publishable_") && publishableKey.utf8.count <= 512 && publishableKey.utf8.allSatisfy { $0 > 32 && $0 < 127 },.invalidCredential)
        self.origin = origin;self.account = account;self.project = project;key = publishableKey
    }
    func request(ordinal:Int,authorization:String,timeoutMS:Int) throws -> URLRequest {
        try connectionNeed((0..<14).contains(ordinal) && timeoutMS > 0,.invalidRequest)
        let n = ordinal%7, paths = ["/auth/v1/user","/rest/v1/rpc/get_sync_handshake"]+WindowsHandoffReader.tables.map { "/rest/v1/"+$0 }
        var parts = URLComponents(url:origin,resolvingAgainstBaseURL:false)!;parts.path = paths[n]
        if n >= 2 { parts.queryItems = [URLQueryItem(name:"project_id",value:"eq."+project.uuidString.lowercased()),URLQueryItem(name:"select",value:"*"),URLQueryItem(name:"limit",value:"10000")] }
        guard let url = parts.url else { throw ReceiveConnectionError.invalidRequest }
        var request = URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:Double(timeoutMS)/1000)
        request.httpMethod = n == 1 ? "POST" : "GET"
        request.setValue(authorization,forHTTPHeaderField:"Authorization");request.setValue(key,forHTTPHeaderField:"apikey")
        request.setValue("application/json",forHTTPHeaderField:"Accept");request.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
        if n == 1 {
            request.httpBody = WindowsJSON.object(["p_project_id":.string(project.uuidString.lowercased()),"p_contract_sha256":.string(WindowsHandoffReader.contractSHA)]).encoded(lf:true)
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        }
        if n >= 2 { request.setValue("count=exact",forHTTPHeaderField:"Prefer") }
        return request
    }
}
struct ReceiveHTTPResponse {
    let status:Int, contentRange:String?, bytes:Data
    let baselineReady = false, baselineApplied = false, independentlyVerified = false
}

// Reservation callback must return only after durable precharge AND start-record readback.
// This connection cannot mint a live execution grant or apply a baseline.
final class ReceiveHTTPConnection {
    private let target:ReceiveHTTPTarget, source:ReceiveSessionSource, clock:ABRuntimeClock
    private let leaseCheck:() throws -> Void
    private let protocols:[AnyClass]?
    private var authority:ReceiveActivationAuthority?
    private let lock = NSLock()
    private var active:ReceiveHTTPOperation?, busy = false, failure:ReceiveConnectionError?, next = 0
    private var session:ReceiveSessionLease?
    init(closedLiveTarget:ReceiveHTTPTarget,source:ReceiveSessionSource,clock:ABRuntimeClock,leaseCheck:@escaping () throws -> Void) {
        target = closedLiveTarget;self.source = source;self.clock = clock;self.leaseCheck = leaseCheck;protocols = nil
    }
    // Reserved .invalid origin plus a mandatory catch-all denies fallback to real networking.
    init(offlineTarget:ReceiveHTTPTarget,source:ReceiveSessionSource,clock:ABRuntimeClock,protocolClass:AnyClass,leaseCheck:@escaping () throws -> Void = {}) throws {
        try connectionNeed(offlineTarget.origin.absoluteString == "https://receive-boundary.invalid",.invalidTarget)
        target = offlineTarget;self.source = source;self.clock = clock;self.leaseCheck = leaseCheck
        protocols = [protocolClass,ReceiveNetworkDenyProtocol.self]
    }
    init(authorizedTarget:ReceiveHTTPTarget,authority:ReceiveActivationAuthority?,source:ReceiveSessionSource,clock:ABRuntimeClock,offlineProtocol:AnyClass? = nil,leaseCheck:@escaping () throws -> Void) throws {
        guard let authority else {throw ReceiveConnectionError.closed}
        try connectionNeed(authority.usesClock(clock),.closed)
        try authority.require(.cachedSession);try authority.requireTarget(authorizedTarget)
        if authority.rehearsal {
            guard let offlineProtocol else {throw ReceiveConnectionError.closed}
            protocols=[offlineProtocol,ReceiveNetworkDenyProtocol.self]
        } else {
            try connectionNeed(offlineProtocol == nil,.closed)
            protocols=[]
        }
        try authority.claim(.httpRead)
        target=authorizedTarget;self.authority=authority;self.source=source;self.clock=clock;self.leaseCheck=leaseCheck
    }
    func cancel() {
        lock.lock();failure = .cancelled;let operation = active;lock.unlock();operation?.fail(.cancelled)
    }
    private func check() throws {
        lock.lock();let failed = failure;lock.unlock()
        if let failed { throw failed };try authority?.require(.cachedSession);try authority?.requireTarget(target);try leaseCheck();try session?.check()
    }
    private func begin(_ ordinal:Int) throws {
        lock.lock();defer { lock.unlock() }
        try connectionNeed(protocols != nil,.closed) // Before session read, reservation, or URLSession construction.
        if let failure { throw failure };try connectionNeed(!busy,.busy);try connectionNeed(ordinal == next && next < 14,.reused);busy = true
    }
    private func end() { lock.lock();busy = false;active = nil;lock.unlock() }
    private func setActive(_ operation:ReceiveHTTPOperation) { lock.lock();active = operation;lock.unlock() }
    private func succeeded() { lock.lock();next += 1;lock.unlock() }
    private func stopped(_ error:ReceiveConnectionError) { lock.lock();failure = error;lock.unlock() }
    func send(ordinal:Int,timeoutMS:Int,expiresUTCMS:Int,maxBytes:Int = 4*1024*1024,reserveAndStart:() throws -> Void) async throws -> ReceiveHTTPResponse {
        try authority?.require(.cachedSession);try authority?.requireTarget(target)
        try begin(ordinal)
        defer { end() }
        do {
            try Task.checkCancellation();try connectionNeed((1...60000).contains(timeoutMS) && (1...4*1024*1024).contains(maxBytes),.invalidRequest)
            let start = try clock.sample();try connectionNeed(start.utcMS < expiresUTCMS,.expired)
            if session == nil { session = try source.capture(account:target.account,clock:clock) }
            try check()
            let deadline = try abAdd(start.monoMS,timeoutMS)
            let op = ReceiveHTTPOperation(clock:clock,deadline:deadline,expires:expiresUTCMS,maxBytes:maxBytes,check:{ try self.check() })
            setActive(op)
            try reserveAndStart() // No suspension before caller-owned durable reservation.
            try op.checkNow()
            let request = try target.request(ordinal:ordinal,authorization:session!.authorization(),timeoutMS:timeoutMS)
            try op.checkNow()
            let response = try await withTaskCancellationHandler(operation:{
                try Task.checkCancellation()
                return try await op.perform(request,protocols:protocols!)
            },onCancel:{ op.fail(.cancelled) })
            try op.checkNow();try Task.checkCancellation()
            succeeded();return response
        } catch {
            let safe = (error as? ReceiveConnectionError) ?? (error is CancellationError ? .cancelled : .reservation)
            stopped(safe);throw safe
        }
    }
}

// A native streaming URLSession operation; tests replace only the URL loading protocol.
final class ReceiveHTTPOperation:NSObject,URLSessionDataDelegate,URLSessionTaskDelegate,@unchecked Sendable {
    private let lock = NSRecursiveLock(), clock:ABRuntimeClock, deadline:Int, expires:Int, maxBytes:Int, boundaryCheck:() throws -> Void
    private var lastUTC:Int?, lastMono:Int?, continuation:CheckedContinuation<ReceiveHTTPResponse,Error>?
    private var failure:ReceiveConnectionError?, session:URLSession?, task:URLSessionDataTask?, timer:DispatchSourceTimer?
    private var bytes = Data(), status:Int?, range:String?, expectedLength:Int64 = -1, completed = false
    init(clock:ABRuntimeClock,deadline:Int,expires:Int,maxBytes:Int,check:@escaping () throws -> Void) { self.clock = clock;self.deadline = deadline;self.expires = expires;self.maxBytes = maxBytes;boundaryCheck = check }
    func checkNow() throws {
        lock.lock();defer { lock.unlock() }
        if let failure { throw failure }
        do {
            try boundaryCheck();let now = try clock.sample()
            if let lastUTC,let lastMono { try connectionNeed(now.utcMS >= lastUTC && now.monoMS >= lastMono,.clock) }
            try connectionNeed(now.utcMS < expires,.expired);try connectionNeed(now.monoMS < deadline,.timeout)
            lastUTC = now.utcMS;lastMono = now.monoMS
        } catch { let safe = (error as? ReceiveConnectionError) ?? .cancelled;failure = safe;throw safe }
    }
    func perform(_ request:URLRequest,protocols:[AnyClass]) async throws -> ReceiveHTTPResponse {
        try await withCheckedThrowingContinuation { c in
            lock.lock();defer { lock.unlock() };continuation = c
            do {
                try checkNow()
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = protocols;config.urlCache = nil;config.httpCookieStorage = nil;config.urlCredentialStorage = nil
                config.httpShouldSetCookies = false;config.requestCachePolicy = .reloadIgnoringLocalCacheData;config.waitsForConnectivity = false
                config.timeoutIntervalForRequest = request.timeoutInterval;config.timeoutIntervalForResource = request.timeoutInterval
                let q = OperationQueue();q.maxConcurrentOperationCount = 1
                let session = URLSession(configuration:config,delegate:self,delegateQueue:q);self.session = session
                let task = session.dataTask(with:request);self.task = task
                let timer = DispatchSource.makeTimerSource(queue:DispatchQueue(label:"receive-boundary.deadline"));self.timer = timer
                timer.schedule(deadline:.now(),repeating:.milliseconds(10))
                timer.setEventHandler { [weak self] in guard let self else { return };do { try self.checkNow() } catch { self.fail((error as? ReceiveConnectionError) ?? .cancelled) } }
                timer.resume();try checkNow();task.resume()
            } catch { finish(.failure((error as? ReceiveConnectionError) ?? .transport)) }
        }
    }
    func fail(_ error:ReceiveConnectionError) { lock.lock();defer { lock.unlock() };failure = failure ?? error;if continuation != nil { finish(.failure(failure!)) } }
    private func finish(_ result:Result<ReceiveHTTPResponse,Error>) {
        lock.lock();defer { lock.unlock() }
        guard !completed else { return };completed = true
        let c = continuation;continuation = nil
        timer?.cancel();timer = nil;task?.cancel();task = nil;session?.invalidateAndCancel();session = nil
        bytes.removeAll(keepingCapacity:false);c?.resume(with:result)
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping (URLSession.ResponseDisposition)->Void) {
        lock.lock();defer { lock.unlock() }
        do {
            try checkNow();guard let http = response as? HTTPURLResponse else { throw ReceiveConnectionError.response }
            try connectionNeed(http.url == dataTask.originalRequest?.url,.response)
            try connectionNeed(http.statusCode != 401,.authentication)
            try connectionNeed(!(300..<400).contains(http.statusCode),.redirect)
            try connectionNeed(http.statusCode == 200 || http.statusCode == 206,.status)
            let encoding = http.value(forHTTPHeaderField:"Content-Encoding")?.lowercased()
            try connectionNeed(encoding == nil || encoding == "identity",.response)
            expectedLength = http.expectedContentLength
            try connectionNeed(expectedLength <= maxBytes,.tooLarge)
            if let length = http.value(forHTTPHeaderField:"Content-Length") { try connectionNeed(Int64(length) == expectedLength && expectedLength >= 0,.response) }
            status = http.statusCode;range = http.value(forHTTPHeaderField:"Content-Range")
            try connectionNeed((range?.utf8.count ?? 0) <= 256,.response)
            completionHandler(.allow)
        } catch { completionHandler(.cancel);fail((error as? ReceiveConnectionError) ?? .response) }
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) {
        lock.lock();defer { lock.unlock() };guard !completed else { return }
        do { try checkNow();try connectionNeed(data.count <= maxBytes-bytes.count,.tooLarge);bytes.append(data) }
        catch { fail((error as? ReceiveConnectionError) ?? .response) }
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
        lock.lock();defer { lock.unlock() };guard !completed else { return }
        do {
            try checkNow()
            if let error {
                if let urlError = error as? URLError, urlError.code == .timedOut { throw ReceiveConnectionError.timeout }
                if let urlError = error as? URLError, urlError.code == .cancelled { throw ReceiveConnectionError.cancelled }
                throw ReceiveConnectionError.transport
            }
            guard let status else { throw ReceiveConnectionError.response }
            try connectionNeed(expectedLength < 0 || expectedLength == bytes.count,.response)
            finish(.success(.init(status:status,contentRange:range,bytes:bytes)))
        } catch { finish(.failure((error as? ReceiveConnectionError) ?? .transport)) }
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) { completionHandler(nil);fail(.redirect) }
    func urlSession(_ session:URLSession,task:URLSessionTask,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping (URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
        do { try checkNow() } catch { completionHandler(.cancelAuthenticationChallenge,nil);fail(.cancelled);return }
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling,nil) }
        else { completionHandler(.cancelAuthenticationChallenge,nil);fail(.authentication) }
    }
}
final class ReceiveNetworkDenyProtocol:URLProtocol {
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() { client?.urlProtocol(self,didFailWithError:URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

// Dedicated password login: separate from the 14-request receive authority and budget.
// No SDK storage, refresh, retries, sign-up or implicit session restoration.
struct ReceivePasswordAuthTarget {
    let origin:URL, account:UUID
    private let key:String
    init(origin:URL,account:UUID,publishableKey:String) throws {
        guard var c=URLComponents(url:origin,resolvingAgainstBaseURL:false) else {throw ReceiveConnectionError.invalidTarget}
        try connectionNeed(c.scheme=="https" && c.host != nil && c.user==nil && c.password==nil && c.port==nil && (c.path.isEmpty || c.path=="/") && c.query==nil && c.fragment==nil,.invalidTarget)
        try connectionNeed(publishableKey.hasPrefix("sb_publishable_") && publishableKey.utf8.count<=512 && publishableKey.utf8.allSatisfy{$0>32 && $0<127},.invalidCredential)
        c.path="";guard let normalized=c.url else {throw ReceiveConnectionError.invalidTarget}
        self.origin=normalized;self.account=account;key=publishableKey
    }
    func request(_ input:ReceiveLoginInput,timeoutMS:Int) throws -> URLRequest {
        try connectionNeed((1...30000).contains(timeoutMS),.invalidRequest)
        try connectionNeed(!input.email.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && input.email.utf8.count<=320 && !input.password.isEmpty && input.password.utf8.count<=4096,.invalidCredential)
        var c=URLComponents(url:origin,resolvingAgainstBaseURL:false)!
        c.path="/auth/v1/token";c.queryItems=[.init(name:"grant_type",value:"password")]
        guard let url=c.url else {throw ReceiveConnectionError.invalidTarget}
        var request=URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData,timeoutInterval:Double(timeoutMS)/1000)
        request.httpMethod="POST"
        request.setValue(key,forHTTPHeaderField:"apikey")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        request.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
        request.httpBody=WindowsJSON.object(["email":.string(input.email),"password":.string(input.password)]).encoded()
        return request
    }
}

final class ReceivePasswordAuthTransport {
    let target:ReceivePasswordAuthTarget
    private let clock:ABRuntimeClock, protocols:[AnyClass]?, timeoutMS:Int
    private let lock=NSLock()
    private var busy=false
    init(closedTarget:ReceivePasswordAuthTarget,clock:ABRuntimeClock=ABRuntimeClock()) {
        target=closedTarget;self.clock=clock;protocols=nil;timeoutMS=15000
    }
    private init(target:ReceivePasswordAuthTarget,clock:ABRuntimeClock,protocols:[AnyClass],timeoutMS:Int) throws {
        try connectionNeed((1...30000).contains(timeoutMS),.invalidRequest)
        self.target=target;self.clock=clock;self.protocols=protocols;self.timeoutMS=timeoutMS
    }
    static func offline(target:ReceivePasswordAuthTarget,clock:ABRuntimeClock,protocolClass:AnyClass,timeoutMS:Int=15000) throws -> ReceivePasswordAuthTransport {
        try connectionNeed(["https://receive-boundary.invalid","https://synthetic.invalid"].contains(target.origin.absoluteString),.invalidTarget)
        return try .init(target:target,clock:clock,protocols:[protocolClass,ReceiveNetworkDenyProtocol.self],timeoutMS:timeoutMS)
    }
    // Trusted composition may select this route only for a separately authorized login stage.
    // Construction performs no request; the UI's explicit sign-in action calls signIn.
    static func live(target:ReceivePasswordAuthTarget,clock:ABRuntimeClock=ABRuntimeClock()) throws -> ReceivePasswordAuthTransport {
        try connectionNeed(clock.isSystem && target.origin.host?.hasSuffix(".invalid")==false,.closed)
        return try .init(target:target,clock:clock,protocols:[],timeoutMS:15000)
    }
    private func begin() throws {
        lock.lock();defer{lock.unlock()}
        try connectionNeed(protocols != nil,.closed);try connectionNeed(!busy,.busy);busy=true
    }
    private func end() {lock.lock();busy=false;lock.unlock()}
    func signIn(_ input:ReceiveLoginInput) async throws -> ReceiveCachedSession {
        try begin();defer{end()}
        do {
            try Task.checkCancellation()
            let start=try clock.sample(),request=try target.request(input,timeoutMS:timeoutMS)
            let op=ReceiveHTTPOperation(clock:clock,deadline:try abAdd(start.monoMS,timeoutMS),expires:try abAdd(start.utcMS,timeoutMS),maxBytes:64*1024,check:{})
            let response=try await withTaskCancellationHandler(operation:{
                try Task.checkCancellation()
                return try await op.perform(request,protocols:protocols!)
            },onCancel:{op.fail(.cancelled)})
            try op.checkNow();try Task.checkCancellation()
            try connectionNeed(response.status==200,.authentication)
            let result=try parse(response.bytes,startedUTCMS:start.utcMS)
            try op.checkNow();try Task.checkCancellation()
            return result
        } catch {
            // Neither the server's body nor error description can reach UI diagnostics.
            throw (error as? ReceiveConnectionError) ?? (error is CancellationError ? .cancelled:.authentication)
        }
    }
    private func parse(_ bytes:Data,startedUTCMS:Int) throws -> ReceiveCachedSession {
        let value=try WindowsJSON.decode(bytes,limit:64*1024)
        try connectionNeed(value.str("token_type").lowercased()=="bearer",.authentication)
        guard let account=UUID(uuidString:try value.get("user").str("id")) else {throw ReceiveConnectionError.authentication}
        try connectionNeed(account==target.account,.authentication)
        let absolute=try value.get("expires_at").int(1),relative=try value.get("expires_in").int(1)
        let ceiling=9_007_199_254_740_991/1000
        try connectionNeed(absolute<=ceiling && relative<=ceiling,.expired)
        // Relative expiration starts before the request; network time cannot extend the session.
        let expiry=min(absolute*1000,try abAdd(startedUTCMS,relative*1000))
        let session=ReceiveCachedSession(account:account,accessToken:try value.str("access_token"),expiresUTCMS:expiry)
        let validator=ReceiveAuthOwner();try validator.replaceCachedSession(session)
        _ = try validator.source.capture(account:target.account,clock:clock)
        return session // refresh_token and user metadata are intentionally not retained.
    }
    @MainActor func authentication(configuration:ReceiveAppPreparation.Configuration) throws -> ReceiveDedicatedAuthentication {
        try connectionNeed(protocols != nil,.closed)
        guard let endpoint=configuration.draft.endpoint,let url=URL(string:endpoint) else {throw ReceiveConnectionError.invalidTarget}
        try connectionNeed(configuration.target.binding.str("endpoint")==endpoint && configuration.target.binding.str("account_id")==target.account.uuidString.lowercased(),.invalidTarget)
        let configured=try ReceivePasswordAuthTarget(origin:url,account:configuration.draft.account ?? target.account,publishableKey:configuration.publishableKey)
        try connectionNeed(configuration.draft.account==target.account && configured.origin==target.origin && configured.keyMatches(target),.invalidTarget)
        return ReceiveDedicatedAuthentication(account:target.account,clock:clock,destination:target.origin.absoluteString,authenticate:{try await self.signIn($0)})
    }
}

private extension ReceivePasswordAuthTarget {
    func keyMatches(_ other:ReceivePasswordAuthTarget)->Bool {key==other.key}
}
