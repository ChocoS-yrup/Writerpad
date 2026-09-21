import XCTest
import Foundation
@testable import AuthHost
private final class Observer:ReceiveAuthObserving,@unchecked Sendable {
    private let lock=NSLock();private var events:[String]=[]
    func begin(_ operationID:UUID){lock.lock();events.append("begin");lock.unlock()}
    func accept(_ operationID:UUID,account:UUID,accessToken:String,expiresAt:Date?){lock.lock();events.append("accept");lock.unlock()}
    func invalidate(){lock.lock();events.append("invalidate");lock.unlock()}
    var values:[String]{lock.lock();defer{lock.unlock()};return events}
}
private actor Store:SessionTokenStoring {
    var tokens:StoredSessionTokens?;var saves=0,loads=0,deletes=0;var failSave=false
    func load() -> StoredSessionTokens?{loads+=1;return tokens}
    func save(_ tokens:StoredSessionTokens)throws{if failSave{throw GeneralValidationFailure.denied};saves+=1;self.tokens=tokens}
    func delete(){deletes+=1;tokens=nil}
    func seed(){tokens = .init(accessToken:"synthetic.access",refreshToken:"synthetic.refresh",expiresAt:Date(timeIntervalSince1970:6000))}
    func rejectSave(){failSave=true}
}
private actor Transport:SupabaseAuthTransporting {
    let session=ValidatedAuthSession(userID:UUID(uuidString:"ee260915-0000-4000-8000-000000000091")!,email:nil,accessToken:"synthetic.access",refreshToken:"synthetic.refresh",expiresAt:Date(timeIntervalSince1970:6000))
    var confirmation=false
    func requireConfirmation(){confirmation=true}
    var failure:SupabaseAuthTransportError?,started:(()->Void)?,gate:CheckedContinuation<Void,Never>?,hold=false
    func configure(_ error:SupabaseAuthTransportError?){failure=error}
    func pause(_ started:@escaping ()->Void){hold=true;self.started=started}
    func release(){hold=false;gate?.resume();gate=nil}
    func response() async throws -> ValidatedAuthSession {started?();if hold{await withCheckedContinuation{gate=$0}};if let failure{throw failure};return session}
    func signIn(email:String,password:String) async throws -> ValidatedAuthSession {try await response()}
    func restore(tokens:StoredSessionTokens) async throws -> ValidatedAuthSession {try await response()}
    func refresh(tokens:StoredSessionTokens) async throws -> ValidatedAuthSession {try await response()}
    func signUp(email:String,password:String) async throws -> SupabaseSignUpResult {if confirmation{return .confirmationRequired(email:nil)};return .authenticated(try await response())}
    func signOut() async throws {}
}
final class CallSiteTests:XCTestCase {
    private func service(_ t:Transport,_ s:Store,_ o:Observer?=nil)->SupabaseAuthService {SupabaseAuthService(transport:t,sessionStore:s,receiveObserver:o,now:{Date(timeIntervalSince1970:1000)})}
    override func setUp(){ReceiveValidationPolicy.current=ReceiveValidationPolicy()}
    func testConstructorDefaultAndObserverArePassive() async {
        let t=Transport(),s=Store(),o=Observer();_ = service(t,s);_ = service(t,s,o);XCTAssertTrue(o.values.isEmpty);let loads=await s.loads;XCTAssertEqual(loads,0)
    }
    func testAcceptedLoginFollowsBeginAndDurableStoreAcceptance() async {
        let t=Transport(),s=Store(),o=Observer(),a=service(t,s,o);let state=await a.signIn(email:"fake@example.invalid",password:"synthetic")
        XCTAssertTrue(state.isAuthenticated);XCTAssertEqual(o.values,["begin","accept"]);let saves=await s.saves;XCTAssertEqual(saves,1)
    }
    func testFailedLoginInvalidatesWithoutAccept() async {
        let t=Transport(),s=Store(),o=Observer();await t.configure(.invalidCredentials);_ = await service(t,s,o).signIn(email:"fake@example.invalid",password:"synthetic");XCTAssertEqual(o.values,["begin","invalidate"])
    }
    func testFailedPersistenceDoesNotPublishCachedSession() async {
        let t=Transport(),s=Store(),o=Observer();await s.rejectSave();_ = await service(t,s,o).signIn(email:"fake@example.invalid",password:"synthetic");XCTAssertEqual(o.values,["begin","invalidate"])
    }
    func testRestoreAndSameAccountRefreshBothReportNewOperation() async {
        let t=Transport(),s=Store(),o=Observer(),a=service(t,s,o);await s.seed();_ = await a.restoreSession();_ = await a.refreshSession(force:true)
        XCTAssertEqual(o.values,["begin","accept","begin","accept"])
    }
    func testRefreshFailureRevokesAcceptedSession() async {
        let t=Transport(),s=Store(),o=Observer(),a=service(t,s,o);_ = await a.signIn(email:"fake@example.invalid",password:"synthetic");await t.configure(.sessionExpired);_ = await a.refreshSession(force:true)
        XCTAssertEqual(o.values,["begin","accept","begin","invalidate"])
    }
    func testSignOutRevokesEvenWhenAlreadySignedOut() async {
        let t=Transport(),s=Store(),o=Observer(),a=service(t,s,o);_ = await a.signOut();_ = await a.signOut();XCTAssertEqual(o.values.filter{$0=="accept"}.count,0);XCTAssertGreaterThanOrEqual(o.values.filter{$0=="invalidate"}.count,2)
    }
    func testValidationBranchAcceptsInMemoryAndLogoutRevokes() async {
        ReceiveValidationPolicy.current.enabled=true;defer{ReceiveValidationPolicy.current=ReceiveValidationPolicy()}
        let t=Transport(),s=Store(),o=Observer(),a=service(t,s,o);_ = await a.signIn(email:"fake@example.invalid",password:"synthetic");_ = await a.signOut();XCTAssertEqual(o.values,["begin","accept","invalidate"]);let saves=await s.saves;XCTAssertEqual(saves,0)
    }
    func testAcceptedSignUpReportsAcceptance() async {
        ReceiveValidationPolicy.current.allowSending=true
        let t=Transport(),s=Store(),o=Observer(),a=service(t,s,o)
        _ = await a.signUp(email:"fake@example.invalid",password:"synthetic")
        XCTAssertEqual(o.values,["begin","accept"])
        _ = await a.signOut()
    }
    func testSignUpConfirmationNeverPublishesSession() async {
        ReceiveValidationPolicy.current.allowSending=true
        let t=Transport(),s=Store(),o=Observer(),a=service(t,s,o);await t.requireConfirmation()
        _ = await a.signUp(email:"fake@example.invalid",password:"synthetic")
        XCTAssertEqual(o.values,["begin","invalidate"])
    }
    func testLateLoginAfterSignOutCannotPublish() async {
        ReceiveValidationPolicy.current.enabled=true;defer{ReceiveValidationPolicy.current=ReceiveValidationPolicy()}
        let t=Transport(),s=Store(),o=Observer(),a=service(t,s,o),entered=expectation(description:"entered")
        await t.pause {entered.fulfill()};let job=Task{await a.signIn(email:"fake@example.invalid",password:"synthetic")}
        await fulfillment(of:[entered],timeout:2);_ = await a.signOut();await t.release();_ = await job.value
        XCTAssertFalse(o.values.contains("accept"))
    }
}
