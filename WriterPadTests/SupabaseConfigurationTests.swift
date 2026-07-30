import XCTest
@testable import WriterPad

final class SupabaseConfigurationTests: XCTestCase {
    func testMissingConfigurationDisablesProvider() {
        let result = SupabasePublicConfiguration.load(from: [:])
        let provider = SupabaseClientProvider(configuration: result)

        XCTAssertEqual(result, .failure(.missing))
        XCTAssertEqual(provider.configurationState, .unavailable(.missing))
        XCTAssertFalse(provider.isConfigured)
        XCTAssertNil(provider.makeSyncV2Client())
    }

    func testInvalidURLDisablesProvider() {
        let result = SupabasePublicConfiguration.load(
            from: values(url: "not-a-url")
        )
        let provider = SupabaseClientProvider(configuration: result)

        XCTAssertEqual(result, .failure(.invalidURL))
        XCTAssertFalse(provider.isConfigured)
    }

    func testValidPublicConfigurationCreatesProviderWithoutNetworkRequest() {
        let result = SupabasePublicConfiguration.load(
            from: values(
                url: "https://writerpad.supabase.co",
                key: "sb_publishable_test_value"
            )
        )
        let provider = SupabaseClientProvider(configuration: result)

        XCTAssertEqual(
            result,
            .success(
                SupabasePublicConfiguration(
                    url: URL(string: "https://writerpad.supabase.co")!,
                    publishableKey: "sb_publishable_test_value"
                )
            )
        )
        XCTAssertTrue(provider.isConfigured)
        XCTAssertNotNil(provider.makeSyncV2Client())
    }

    func testEphemeralAuthStorageRetainsSessionForSameProcessOnly() throws {
        let storage = EphemeralAuthLocalStorage()
        let session = Data("validated-session".utf8)

        try storage.store(key: "supabase.auth.token", value: session)

        XCTAssertEqual(
            try storage.retrieve(key: "supabase.auth.token"),
            session
        )
        try storage.remove(key: "supabase.auth.token")
        XCTAssertNil(try storage.retrieve(key: "supabase.auth.token"))

        let newProcessStorage = EphemeralAuthLocalStorage()
        XCTAssertNil(
            try newProcessStorage.retrieve(key: "supabase.auth.token")
        )
    }

    func testServiceRoleJWTIsRejected() throws {
        let header = try base64URL(["alg": "HS256", "typ": "JWT"])
        let payload = try base64URL(["role": "service_role"])
        let result = SupabasePublicConfiguration.load(
            from: values(key: "\(header).\(payload).signature")
        )

        XCTAssertEqual(result, .failure(.forbiddenCredential))
    }

    @MainActor
    func testMissingSupabaseConfigurationDoesNotBlockLocalEnvironment() throws {
        let environment = try AppEnvironment.testing()

        XCTAssertFalse(environment.supabaseClientProvider.isConfigured)
        XCTAssertEqual(
            environment.supabaseClientProvider.configurationState,
            .unavailable(.missing)
        )
    }

    private func values(
        url: String = "https://writerpad.supabase.co",
        key: String = "sb_publishable_test_value"
    ) -> [String: Any] {
        [
            SupabasePublicConfiguration.Keys.url: url,
            SupabasePublicConfiguration.Keys.publishableKey: key,
        ]
    }

    private func base64URL(_ object: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return data.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
}
