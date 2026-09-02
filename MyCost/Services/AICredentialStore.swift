import Foundation
import Security

/// The secret material for one AI provider. Held **only** in the Keychain —
/// never in SwiftData, never on ``AIProviderConnection``. `accessToken` /
/// `refreshToken` / `expiresAt` are reserved for a future OAuth grant.
struct AIProviderSecret: Equatable, Codable {
    var apiKey: String?
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Date?

    var isUsable: Bool {
        if let apiKey, !apiKey.isEmpty { return true }
        if let accessToken, !accessToken.isEmpty { return true }
        return false
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    static func key(_ apiKey: String) -> AIProviderSecret {
        AIProviderSecret(apiKey: apiKey)
    }
}

protocol AISecretStore: AnyObject, Sendable {
    func secret(for account: String) -> AIProviderSecret?
    func save(_ secret: AIProviderSecret, for account: String) throws
    func delete(for account: String) throws
}

final class InMemoryAISecretStore: AISecretStore, @unchecked Sendable {
    private var storage: [String: AIProviderSecret]

    init(storage: [String: AIProviderSecret] = [:]) {
        self.storage = storage
    }

    func secret(for account: String) -> AIProviderSecret? { storage[account] }
    func save(_ secret: AIProviderSecret, for account: String) throws { storage[account] = secret }
    func delete(for account: String) throws { storage[account] = nil }
}

enum KeychainAISecretStoreError: Error {
    case unexpectedStatus(OSStatus)
}

/// Generic-password Keychain storage, one item per provider account.
final class KeychainAISecretStore: AISecretStore, @unchecked Sendable {
    private let service: String

    init(service: String = "com.getsuzym.MyCost.ai-secrets") {
        self.service = service
    }

    func secret(for account: String) -> AIProviderSecret? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(AIProviderSecret.self, from: data)
    }

    func save(_ secret: AIProviderSecret, for account: String) throws {
        let data = try JSONEncoder().encode(secret)
        try delete(for: account)

        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainAISecretStoreError.unexpectedStatus(status)
        }
    }

    func delete(for account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainAISecretStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
