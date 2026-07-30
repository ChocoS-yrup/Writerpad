import Foundation
import Security

struct StoredSessionTokens: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
}

protocol SessionTokenStoring: Sendable {
    func load() async throws -> StoredSessionTokens?
    func save(_ tokens: StoredSessionTokens) async throws
    func delete() async throws
}

enum KeychainSessionStoreError: Error, Equatable, Sendable {
    case invalidData
    case unexpectedStatus(OSStatus)
}

actor KeychainSessionStore: SessionTokenStoring {
    private let service: String
    private let account: String

    init(
        service: String = "com.chocos.writerpad.auth.session",
        account: String = "supabase-session-v1"
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> StoredSessionTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainSessionStoreError.unexpectedStatus(status)
        }
        guard
            let data = item as? Data,
            let tokens = try? JSONDecoder().decode(
                StoredSessionTokens.self,
                from: data
            )
        else {
            throw KeychainSessionStoreError.invalidData
        }
        return tokens
    }

    func save(_ tokens: StoredSessionTokens) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(tokens)
        } catch {
            throw KeychainSessionStoreError.invalidData
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
            throw KeychainSessionStoreError.unexpectedStatus(updateStatus)
        }

        var newItem = baseQuery
        attributes.forEach { newItem[$0.key] = $0.value }
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainSessionStoreError.unexpectedStatus(addStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSessionStoreError.unexpectedStatus(status)
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
