import XCTest
@testable import SyntheticInitialReceive

@MainActor
final class DedicatedAuthenticationTests:XCTestCase {
    let account=UUID(uuidString:"ee260917-0000-4000-8000-000000000111")!
    let clock=ABRuntimeClock(utcMS:1000,monoMS:0)
    var input:ReceiveLoginInput {.init(email:"fixture@example.invalid",password:"synthetic-password")}
    func session(_ token:String="synthetic.session",account:UUID?=nil,expiry:Int=10000)->ReceiveCachedSession {
        .init(account:account ?? self.account,accessToken:token,expiresUTCMS:expiry)
    }
    func testUnconfiguredAndConstructionAreInert() async throws {
        let closed=ReceiveDedicatedAuthentication(account:account,clock:clock)
        XCTAssertFalse(closed.isConfigured)
        XCTAssertThrowsError(try closed.signIn(input))
        var calls=0
        let flow=ReceiveDedicatedAuthentication(account:account,clock:clock,authenticate:{_ in calls+=1;return self.session()})
        XCTAssertEqual(calls,0);XCTAssertEqual(flow.state,.signedOut)
        try flow.owner.replaceCachedSession(session())
        flow.cancel()
        XCTAssertThrowsError(try flow.owner.source.capture(account:account,clock:clock))
    }
    func testSuccessfulLoginThenLogoutRevokesCapturedLease() async throws {
        let flow=ReceiveDedicatedAuthentication(account:account,clock:clock,authenticate:{_ in self.session()})
        let done=expectation(description:"authenticated")
        flow.onStateChange={if $0 == .signedIn {done.fulfill()}}
        try flow.signIn(input);await fulfillment(of:[done],timeout:2)
        let lease=try flow.owner.source.capture(account:account,clock:clock)
        flow.cancel()
        XCTAssertEqual(flow.state,.signedOut);XCTAssertThrowsError(try lease.check())
        XCTAssertThrowsError(try flow.owner.source.capture(account:account,clock:clock))
    }
    func testReplacementRevokesPreviousLeaseBeforeAdapterRuns() async throws {
        let flow=ReceiveDedicatedAuthentication(account:account,clock:clock,authenticate:{_ in throw ReceiveConnectionError.authentication})
        try flow.owner.replaceCachedSession(session())
        let old=try flow.owner.source.capture(account:account,clock:clock)
        var invalidations=0;flow.onInvalidate={invalidations+=1}
        let failed=expectation(description:"failed")
        flow.onStateChange={if $0 == .failed {failed.fulfill()}}
        try flow.signIn(input)
        XCTAssertThrowsError(try old.check());XCTAssertEqual(invalidations,1)
        await fulfillment(of:[failed],timeout:2)
        XCTAssertThrowsError(try flow.owner.source.capture(account:account,clock:clock))
    }
    func testCancelRejectsLateResponseWithoutClearingNewerSession() async throws {
        var calls=0
        var late:CheckedContinuation<ReceiveCachedSession,Never>?
        let entered=expectation(description:"old adapter entered")
        let flow=ReceiveDedicatedAuthentication(account:account,clock:clock,authenticate:{_ in
            calls+=1
            if calls==1 {return await withCheckedContinuation{late=$0;entered.fulfill()}}
            return self.session("synthetic.new")
        })
        try flow.signIn(input);await fulfillment(of:[entered],timeout:2)
        XCTAssertThrowsError(try flow.signIn(input));XCTAssertEqual(calls,1)
        flow.cancel()
        let done=expectation(description:"new session")
        flow.onStateChange={if $0 == .signedIn {done.fulfill()}}
        try flow.signIn(input);await fulfillment(of:[done],timeout:2)
        let current=try flow.owner.source.capture(account:account,clock:clock)
        late?.resume(returning:session("synthetic.old"))
        await Task.yield()
        XCTAssertNoThrow(try current.check());XCTAssertEqual(flow.state,.signedIn)
    }
    func testInvalidInputClearsPriorSessionWithoutCallingAdapter() async throws {
        var calls=0
        let flow=ReceiveDedicatedAuthentication(account:account,clock:clock,authenticate:{_ in calls+=1;return self.session()})
        try flow.owner.replaceCachedSession(session())
        XCTAssertThrowsError(try flow.signIn(.init(email:"",password:"secret")))
        XCTAssertEqual(calls,0);XCTAssertEqual(flow.state,.failed)
        XCTAssertThrowsError(try flow.owner.source.capture(account:account,clock:clock))
    }
    func testWrongAccountExpiredAndMalformedTokenNeverPublish() async throws {
        for value in [session(account:UUID()),session(expiry:1000),session("bad token")] {
            let flow=ReceiveDedicatedAuthentication(account:account,clock:clock,authenticate:{_ in value})
            let done=expectation(description:"invalid session")
            flow.onStateChange={if $0 == .failed {done.fulfill()}}
            try flow.signIn(input);await fulfillment(of:[done],timeout:2)
            XCTAssertThrowsError(try flow.owner.source.capture(account:account,clock:clock))
        }
    }
    func testCredentialsDoNotAppearInDescriptionsOrMirror() async throws {
        XCTAssertFalse(String(describing:input).contains(input.password))
        XCTAssertFalse(String(reflecting:input).contains(input.email))
        XCTAssertTrue(Mirror(reflecting:input).children.isEmpty)
    }
}
