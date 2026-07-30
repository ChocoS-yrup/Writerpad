import Foundation
import XCTest
@testable import WriterPad

final class DeviceIdentityServiceTests: XCTestCase {
    func testFirstRequestCreatesAndPersistsOneIdentifier() async throws {
        let expected = identifier("00000000-0000-0000-0000-000000000093")
        let store = DeviceIdentityStoreStub()
        let service = DeviceIdentityService(
            store: store,
            generateUUID: { expected.uuid }
        )

        let first = try await service.currentIdentifier()
        let second = try await service.currentIdentifier()
        let stored = await store.storedIdentifier()
        let saveCount = await store.saveCallCount()

        XCTAssertEqual(first, expected)
        XCTAssertEqual(second, expected)
        XCTAssertEqual(stored, expected)
        XCTAssertEqual(saveCount, 1)
        let state = await service.currentState()
        XCTAssertEqual(state, .ready(expected))
    }

    func testNewServiceRestoresIdentifierWithoutGeneratingAnother() async throws {
        let stored = identifier("00000000-0000-0000-0000-000000000094")
        let store = DeviceIdentityStoreStub(identifier: stored)
        let service = DeviceIdentityService(
            store: store,
            generateUUID: {
                XCTFail("A stored identity must not be replaced.")
                return UUID()
            }
        )

        let restored = try await service.currentIdentifier()

        XCTAssertEqual(restored, stored)
        let saveCount = await store.saveCallCount()
        XCTAssertEqual(saveCount, 0)
    }

    func testConcurrentRequestsCoalesceToOneCreation() async throws {
        let store = DeviceIdentityStoreStub(loadDelayNanoseconds: 20_000_000)
        let service = DeviceIdentityService(store: store)

        let identifiers = try await withThrowingTaskGroup(
            of: DeviceIdentifier.self
        ) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await service.currentIdentifier()
                }
            }
            var values: [DeviceIdentifier] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        XCTAssertEqual(Set(identifiers).count, 1)
        let saveCount = await store.saveCallCount()
        XCTAssertEqual(saveCount, 1)
    }

    func testCorruptStoredIdentityFailsClosedWithoutReplacement() async {
        let store = DeviceIdentityStoreStub(loadError: .invalidData)
        let service = DeviceIdentityService(store: store)

        do {
            _ = try await service.currentIdentifier()
            XCTFail("Corrupt identity must not be silently replaced.")
        } catch {
            XCTAssertEqual(
                error as? DeviceIdentityFailure,
                .invalidStoredIdentity
            )
        }

        let state = await service.currentState()
        let saveCount = await store.saveCallCount()
        XCTAssertEqual(state, .unavailable(.invalidStoredIdentity))
        XCTAssertEqual(saveCount, 0)
    }

    func testKeychainFailureIsDistinctAndDoesNotCreateIdentity() async {
        let store = DeviceIdentityStoreStub(
            loadError: .unexpectedStatus(-1)
        )
        let service = DeviceIdentityService(store: store)

        do {
            _ = try await service.currentIdentifier()
            XCTFail("Keychain failure must be surfaced.")
        } catch {
            XCTAssertEqual(error as? DeviceIdentityFailure, .keychainAccess)
        }

        let state = await service.currentState()
        let saveCount = await store.saveCallCount()
        XCTAssertEqual(state, .unavailable(.keychainAccess))
        XCTAssertEqual(saveCount, 0)
    }

    func testDescriptionMasksFullIdentifier() {
        let value = identifier("12345678-1234-1234-1234-1234567890AB")

        XCTAssertEqual(value.description, "device_12345678…90ab")
        XCTAssertEqual(value.redactedDescription, value.description)
        XCTAssertEqual(String(reflecting: value), value.description)
        XCTAssertFalse(value.description.contains(value.storedValue))
    }

    func testExistingOperationKeepsCapturedIdentityAfterRotation() {
        let captured = identifier("00000000-0000-0000-0000-000000000095")
        let current = identifier("00000000-0000-0000-0000-000000000096")

        let decision = OperationDeviceIdentityPolicy.resolve(
            capturedIdentifier: captured,
            currentIdentifier: current
        )

        XCTAssertEqual(decision.identifierForRetry, captured)
        XCTAssertTrue(decision.identityChangedSinceEnqueue)
        XCTAssertTrue(decision.preservesExistingOperation)
    }

    func testLegacyOperationWithoutCapturedIdentityUsesCurrentWithoutDeletion() {
        let current = identifier("00000000-0000-0000-0000-000000000097")

        let decision = OperationDeviceIdentityPolicy.resolve(
            capturedIdentifier: nil,
            currentIdentifier: current
        )

        XCTAssertEqual(decision.identifierForRetry, current)
        XCTAssertFalse(decision.identityChangedSinceEnqueue)
        XCTAssertTrue(decision.preservesExistingOperation)
    }

    func testKeychainStoreRoundTripsAndDeletesIdentifier() async throws {
        let store = KeychainDeviceIdentityStore(
            service: "com.chocos.writerpad.tests.\(UUID().uuidString)",
            account: "isolated-device"
        )
        let value = identifier("00000000-0000-0000-0000-000000000098")

        try await store.delete()
        let initial = try await store.load()
        XCTAssertNil(initial)

        try await store.save(value)
        let restored = try await store.load()
        XCTAssertEqual(restored, value)

        try await store.delete()
        let deleted = try await store.load()
        XCTAssertNil(deleted)
    }

    @MainActor
    func testTestingEnvironmentProvidesStableIdentityWithoutBlockingLocalMode()
        async throws {
        let environment = try AppEnvironment.testing()

        await environment.deviceIdentityService.prepareIdentity()
        let first = try await environment.deviceIdentityService
            .currentIdentifier()
        let second = try await environment.deviceIdentityService
            .currentIdentifier()

        XCTAssertEqual(first, second)
        let state = await environment.deviceIdentityService.currentState()
        XCTAssertEqual(state, .ready(first))
        XCTAssertEqual(environment.storageStatus, .ready)
    }

    private func identifier(_ value: String) -> DeviceIdentifier {
        DeviceIdentifier(uuid: UUID(uuidString: value)!)
    }
}

private actor DeviceIdentityStoreStub: DeviceIdentityStoring {
    private var identifier: DeviceIdentifier?
    private let loadError: DeviceIdentityStoreError?
    private let loadDelayNanoseconds: UInt64
    private var saves = 0

    init(
        identifier: DeviceIdentifier? = nil,
        loadError: DeviceIdentityStoreError? = nil,
        loadDelayNanoseconds: UInt64 = 0
    ) {
        self.identifier = identifier
        self.loadError = loadError
        self.loadDelayNanoseconds = loadDelayNanoseconds
    }

    func load() async throws -> DeviceIdentifier? {
        if loadDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: loadDelayNanoseconds)
        }
        if let loadError {
            throw loadError
        }
        return identifier
    }

    func save(_ identifier: DeviceIdentifier) {
        saves += 1
        self.identifier = identifier
    }

    func delete() {
        identifier = nil
    }

    func storedIdentifier() -> DeviceIdentifier? {
        identifier
    }

    func saveCallCount() -> Int {
        saves
    }
}
