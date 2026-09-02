import Foundation
import Security

/// Credentials for the end user's own AI account. The app never ships a key of
/// its own — this is populated only when the user connects a service.
struct AIProviderConnection: Equatable, Codable {
    /// Identifies the wire format to speak. Currently only `"openai-compatible"`
    /// (Chat Completions style) is implemented, but the field lets other
    /// providers be added without a migration.
    var providerID: String
    /// Full endpoint URL the user pasted, e.g.
    /// `https://api.openai.com/v1/chat/completions` or a self-hosted proxy.
    var endpointURL: URL
    var apiKey: String
    var model: String

    init(providerID: String = "openai-compatible", endpointURL: URL, apiKey: String, model: String) {
        self.providerID = providerID
        self.endpointURL = endpointURL
        self.apiKey = apiKey
        self.model = model
    }
}

/// Storage seam for the connection above. The app uses the Keychain-backed
/// implementation; tests and previews use ``InMemoryAICredentialStore``.
protocol AICredentialStoring: AnyObject, Sendable {
    func loadConnection() -> AIProviderConnection?
    func save(_ connection: AIProviderConnection) throws
    func clear() throws
}

final class InMemoryAICredentialStore: AICredentialStoring, @unchecked Sendable {
    private var connection: AIProviderConnection?

    init(connection: AIProviderConnection? = nil) {
        self.connection = connection
    }

    func loadConnection() -> AIProviderConnection? { connection }
    func save(_ connection: AIProviderConnection) throws { self.connection = connection }
    func clear() throws { connection = nil }
}

enum KeychainAICredentialStoreError: Error {
    case unexpectedStatus(OSStatus)
}

/// Persists a single `AIProviderConnection` as a generic-password item.
final class KeychainAICredentialStore: AICredentialStoring, @unchecked Sendable {
    private let service: String
    private let account: String

    init(service: String = "com.getsuzym.MyCost.ai-credentials", account: String = "default") {
        self.service = service
        self.account = account
    }

    func loadConnection() -> AIProviderConnection? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(AIProviderConnection.self, from: data)
    }

    func save(_ connection: AIProviderConnection) throws {
        let data = try JSONEncoder().encode(connection)
        try clear()

        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainAICredentialStoreError.unexpectedStatus(status)
        }
    }

    func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainAICredentialStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
