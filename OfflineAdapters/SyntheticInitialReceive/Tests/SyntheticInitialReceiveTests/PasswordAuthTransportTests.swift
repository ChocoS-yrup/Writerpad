import XCTest
@testable import SyntheticInitialReceive

final class PasswordAuthTransportTests:XCTestCase {
    let account=UUID(uuidString:"ee260917-0000-4000-8000-000000000201")!
    let clock=ABRuntimeClock(utcMS:1000,monoMS:0)
    var input:ReceiveLoginInput {.init(email:"fixture@example.invalid",password:"synthetic-\"password\n")}
    func target(_ origin:String="https://receive-boundary.invalid",key:String="sb_publishable_fixture") throws -> ReceivePasswordAuthTarget {
        try .init(origin:URL(string:origin)!,account:account,publishableKey:key)
    }
    func transport(protocolClass:AnyClass=ReceiveStubProtocol.self,timeoutMS:Int=15000) throws -> ReceivePasswordAuthTransport {
        try .offline(target:target(),clock:clock,protocolClass:protocolClass,timeoutMS:timeoutMS)
    }
    func body(_ changes:[String:WindowsJSON]=[:]) throws -> Data {
        var fields:[String:WindowsJSON]=["access_token":.string("synthetic.access.token"),"token_type":.string("bearer"),"expires_at":.number("10"),"expires_in":.number("9"),"user":.object(["id":.string(account.uuidString.lowercased())]),"refresh_token":.string("synthetic.refresh.discard")]
        fields.merge(changes){_,new in new};return WindowsJSON.object(fields).encoded()
    }
    override func setUp() {ReceiveStubProtocol.configure()}
    override func tearDown() {ReceiveStubProtocol.configure()}
    func testRequestContainsOnlyPasswordGrantAndJSONCredentials() throws {
        let request=try target().request(input,timeoutMS:1000)
        XCTAssertEqual(request.url?.absoluteString,"https://receive-boundary.invalid/auth/v1/token?grant_type=password")
        XCTAssertEqual(request.httpMethod,"POST");XCTAssertNil(request.value(forHTTPHeaderField:"Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField:"apikey"),"sb_publishable_fixture")
        let decoded=try WindowsJSON.decode(XCTUnwrap(request.httpBody))
        try decoded.keys(["email","password"]);XCTAssertEqual(try decoded.str("password"),input.password)
        XCTAssertFalse(request.url!.absoluteString.contains(input.email))
    }
    func testDefaultClosedAndUnsafeTargetsNeverSend() async throws {
        let closed=ReceivePasswordAuthTransport(closedTarget:try target(),clock:clock)
        do {_ = try await closed.signIn(input);XCTFail()}catch {XCTAssertEqual(error as? ReceiveConnectionError,.closed)}
        for origin in ["http://receive-boundary.invalid","https://user:pass@receive-boundary.invalid","https://receive-boundary.invalid/extra","https://receive-boundary.invalid?x=1"] {XCTAssertThrowsError(try target(origin))}
        XCTAssertThrowsError(try target(key:"service-role"))
        XCTAssertThrowsError(try ReceivePasswordAuthTransport.live(target:target(),clock:clock))
        XCTAssertEqual(ReceiveStubProtocol.captured().count,0)
    }
    func testSuccessfulLoginRetainsOnlyBoundSessionAndUsesConservativeExpiry() async throws {
        ReceiveStubProtocol.configure(.init(chunks:[try body(["expires_at":.number("20")])]))
        let t=try transport();XCTAssertEqual(ReceiveStubProtocol.captured().count,0)
        let session=try await t.signIn(input)
        XCTAssertEqual(session.account,account);XCTAssertEqual(session.expiresUTCMS,10000)
        XCTAssertFalse(String(reflecting:session).contains("refresh"));XCTAssertEqual(ReceiveStubProtocol.captured().count,1)
    }
    func testHTTPFailuresDoNotRetryOrExposeServerBody() async throws {
        for status in [206,302,400,401,429,500] {
            ReceiveStubProtocol.configure(.init(status:status,chunks:[Data("sensitive-server-error".utf8)]))
            do {_ = try await transport().signIn(input);XCTFail("status accepted: \(status)")}catch {
                XCTAssertTrue(error is ReceiveConnectionError);XCTAssertFalse(String(describing:error).contains("sensitive"))
            }
            XCTAssertEqual(ReceiveStubProtocol.captured().count,1)
        }
    }
    func testWrongSubjectExpiryTokenTypeAndTokenFailClosed() async throws {
        for changes:[String:WindowsJSON] in [
            ["user":.object(["id":.string(UUID().uuidString)])],
            ["expires_at":.number("1")],["expires_in":.number("0")],
            ["expires_at":.number("9007199254740991")],
            ["token_type":.string("mac")],["access_token":.string("bad token")]
        ] {
            ReceiveStubProtocol.configure(.init(chunks:[try body(changes)]))
            do {_ = try await transport().signIn(input);XCTFail()}catch {XCTAssertTrue(error is ReceiveConnectionError)}
        }
    }
    func testMalformedDuplicateAndOversizedResponsesAreRejected() async throws {
        for bytes in [Data("{}".utf8),Data("{\"access_token\":\"a\",\"access_token\":\"b\"}".utf8),Data(repeating:65,count:65537)] {
            ReceiveStubProtocol.configure(.init(chunks:[bytes]))
            do {_ = try await transport().signIn(input);XCTFail()}catch {XCTAssertTrue(error is ReceiveConnectionError)}
        }
    }
    func testUnhandledStubCannotFallBackToNetwork() async throws {
        do {_ = try await transport(protocolClass:ReceiveNeverHandlesProtocol.self).signIn(input);XCTFail()}
        catch {XCTAssertEqual(error as? ReceiveConnectionError,.transport)}
        XCTAssertEqual(ReceiveStubProtocol.captured().count,0)
    }
    func testCancellationStopsPendingRequestAndRejectsConcurrentLogin() async throws {
        let entered=expectation(description:"request started")
        ReceiveStubProtocol.configure(.init(hold:true,action:{entered.fulfill()}))
        let t=try transport(),requestInput=input
        let task=Task {try await t.signIn(requestInput)}
        await fulfillment(of:[entered],timeout:2)
        do {_ = try await t.signIn(input);XCTFail()}catch {XCTAssertEqual(error as? ReceiveConnectionError,.busy)}
        task.cancel()
        do {_ = try await task.value;XCTFail()}catch {XCTAssertEqual(error as? ReceiveConnectionError,.cancelled)}
        XCTAssertEqual(ReceiveStubProtocol.captured().count,1)
    }
    func testDeadlineExpirationRejectsResponse() async throws {
        ReceiveStubProtocol.configure(.init(chunks:[try body()],action:{try? self.clock.advance(1000)}))
        do {_ = try await transport(timeoutMS:1000).signIn(input);XCTFail()}
        catch {XCTAssertTrue([ReceiveConnectionError.expired,.timeout].contains(error as? ReceiveConnectionError ?? .transport))}
    }
}
