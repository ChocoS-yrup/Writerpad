import Foundation
import Security

struct DeviceIdentifier:
    Hashable,
    Sendable,
    Codable,
    CustomStringConvertible,
    CustomDebugStringConvertible {
    let uuid: UUID

    init(uuid: UUID) {
        self.uuid = uuid
    }

    init?(storedValue: String) {
        guard let uuid = UUID(uuidString: storedValue) else {
            return nil
        }
        self.uuid = uuid
    }

    var storedValue: String {
        uuid.uuidString.lowercased()
    }

    var redactedDescription: String {
        let compact = storedValue.replacingOccurrences(of: "-", with: "")
        return "device_\(compact.prefix(8))…\(compact.suffix(4))"
    }

    var description: String {
        redactedDescription
    }

    var debugDescription: String {
        redactedDescription
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let identifier = DeviceIdentifier(storedValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid device identifier."
            )
        }
        self = identifier
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storedValue)
    }
}

enum DeviceIdentityStoreError: Error, Equatable, Sendable {
    case invalidData
    case unexpectedStatus(OSStatus)
}

protocol DeviceIdentityStoring: Sendable {
    func load() async throws -> DeviceIdentifier?
    func save(_ identifier: DeviceIdentifier) async throws
    func delete() async throws
}

actor KeychainDeviceIdentityStore: DeviceIdentityStoring {
    private let service: String
    private let account: String

    init(
        service: String = "com.chocos.writerpad.device.identity",
        account: String = "installation-device-v1"
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> DeviceIdentifier? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw DeviceIdentityStoreError.unexpectedStatus(status)
        }
        guard
            let data = item as? Data,
            let value = String(data: data, encoding: .utf8),
            let identifier = DeviceIdentifier(storedValue: value)
        else {
            throw DeviceIdentityStoreError.invalidData
        }
        return identifier
    }

    func save(_ identifier: DeviceIdentifier) throws {
        guard let data = identifier.storedValue.data(using: .utf8) else {
            throw DeviceIdentityStoreError.invalidData
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw DeviceIdentityStoreError.unexpectedStatus(updateStatus)
        }

        var newItem = baseQuery
        attributes.forEach { newItem[$0.key] = $0.value }
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw DeviceIdentityStoreError.unexpectedStatus(addStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceIdentityStoreError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

actor InMemoryDeviceIdentityStore: DeviceIdentityStoring {
    private var identifier: DeviceIdentifier?

    func load() -> DeviceIdentifier? {
        identifier
    }

    func save(_ identifier: DeviceIdentifier) {
        self.identifier = identifier
    }

    func delete() {
        identifier = nil
    }
}

enum DeviceIdentityFailure: Error, Equatable, Sendable {
    case invalidStoredIdentity
    case keychainAccess
}

enum DeviceIdentityState: Equatable, Sendable {
    case uninitialized
    case loading
    case ready(DeviceIdentifier)
    case unavailable(DeviceIdentityFailure)
}

protocol DeviceIdentityProviding: Sendable {
    func currentState() async -> DeviceIdentityState
    func currentIdentifier() async throws -> DeviceIdentifier
    func prepareIdentity() async
}

actor DeviceIdentityService: DeviceIdentityProviding {
    private let store: any DeviceIdentityStoring
    private let generateUUID: @Sendable () -> UUID
    private var state: DeviceIdentityState = .uninitialized
    private var loadingTask: Task<DeviceIdentifier, any Error>?

    init(
        store: any DeviceIdentityStoring,
        generateUUID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.store = store
        self.generateUUID = generateUUID
    }

    func currentState() -> DeviceIdentityState {
        state
    }

    func currentIdentifier() async throws -> DeviceIdentifier {
        if case let .ready(identifier) = state {
            return identifier
        }
        if let loadingTask {
            return try await loadingTask.value
        }

        let store = self.store
        let generateUUID = self.generateUUID
        let task = Task<DeviceIdentifier, any Error> {
            do {
                if let stored = try await store.load() {
                    return stored
                }
                let created = DeviceIdentifier(uuid: generateUUID())
                try await store.save(created)
                return created
            } catch DeviceIdentityStoreError.invalidData {
                throw DeviceIdentityFailure.invalidStoredIdentity
            } catch {
                throw DeviceIdentityFailure.keychainAccess
            }
        }
        loadingTask = task
        state = .loading

        do {
            let identifier = try await task.value
            loadingTask = nil
            state = .ready(identifier)
            return identifier
        } catch let failure as DeviceIdentityFailure {
            loadingTask = nil
            state = .unavailable(failure)
            throw failure
        } catch {
            loadingTask = nil
            state = .unavailable(.keychainAccess)
            throw DeviceIdentityFailure.keychainAccess
        }
    }

    func prepareIdentity() async {
        _ = try? await currentIdentifier()
    }
}

struct OperationDeviceIdentityDecision: Equatable, Sendable {
    let identifierForRetry: DeviceIdentifier
    let identityChangedSinceEnqueue: Bool
    let preservesExistingOperation: Bool
}

enum OperationDeviceIdentityPolicy {
    static func resolve(
        capturedIdentifier: DeviceIdentifier?,
        currentIdentifier: DeviceIdentifier
    ) -> OperationDeviceIdentityDecision {
        guard let capturedIdentifier else {
            return OperationDeviceIdentityDecision(
                identifierForRetry: currentIdentifier,
                identityChangedSinceEnqueue: false,
                preservesExistingOperation: true
            )
        }
        return OperationDeviceIdentityDecision(
            identifierForRetry: capturedIdentifier,
            identityChangedSinceEnqueue:
                capturedIdentifier != currentIdentifier,
            preservesExistingOperation: true
        )
    }
}
