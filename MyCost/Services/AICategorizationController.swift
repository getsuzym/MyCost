import Foundation
import SwiftData

// (Filename kept for project stability; this is the stateless AIProviderService.)

/// All AI-provider connection changes go through here so the ``AIProviderConnection``
/// SwiftData row and the Keychain secret stay in step, and so views never touch
/// the Keychain directly. Mirrors the ``CategoryService`` / ``MerchantRuleService``
/// pattern: a value type, `@MainActor` for the writes.
struct AIProviderService {
    private let secretStore: AISecretStore
    private let transport: AITransport

    init(
        secretStore: AISecretStore = KeychainAISecretStore(),
        transport: @escaping AITransport = defaultAITransport
    ) {
        self.secretStore = secretStore
        self.transport = transport
    }

    // MARK: Reads

    /// The single active connection, if the user has connected one.
    func activeConnection(in connections: [AIProviderConnection]) -> AIProviderConnection? {
        connections.first { $0.isConnected }
    }

    /// Builds the concrete provider for a connection, or nil if it has no
    /// usable secret (revoked key, cleared Keychain…).
    func provider(for connection: AIProviderConnection) -> AIClassificationProvider? {
        guard secretStore.secret(for: connection.provider.keychainAccount)?.isUsable == true else {
            return nil
        }
        return makeProvider(connection.provider, model: connection.model, endpoint: connection.endpointURL)
    }

    func makeCoordinator(
        for connections: [AIProviderConnection],
        minimumConfidence: Double = MerchantCategorizationCoordinator.defaultMinimumConfidence
    ) -> MerchantCategorizationCoordinator {
        let provider = activeConnection(in: connections).flatMap(provider(for:))
        return MerchantCategorizationCoordinator(provider: provider, minimumConfidence: minimumConfidence)
    }

    // MARK: Writes

    /// Connects `provider` with a user-supplied API key: validates it with a
    /// live round-trip, stores the key in the Keychain, and upserts the
    /// connection row as `.connected`. Any previously connected provider is
    /// disconnected first (one active provider at a time).
    @MainActor
    func connectWithAPIKey(
        _ provider: AIProviderKind,
        apiKey: String,
        model: String,
        endpoint: URL,
        existing connections: [AIProviderConnection],
        modelContext: ModelContext
    ) async throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw AIClassificationError.providerUnavailable }

        // Stage the secret so validation can read it, then verify.
        try secretStore.save(.key(trimmedKey), for: provider.keychainAccount)
        do {
            try await makeProvider(provider, model: model, endpoint: endpoint).validateConnection()
        } catch {
            try? secretStore.delete(for: provider.keychainAccount)
            throw error
        }

        for connection in connections where connection.provider != provider {
            try? disconnect(connection, existing: connections, modelContext: modelContext)
        }

        let now = Date()
        if let row = connections.first(where: { $0.provider == provider }) {
            row.state = .connected
            row.model = model
            row.endpointURL = endpoint
            row.authType = .apiKey
            row.connectedAt = now
            row.lastValidatedAt = now
        } else {
            let row = AIProviderConnection(
                provider: provider, state: .connected, authType: .apiKey,
                model: model, endpointURL: endpoint, connectedAt: now, lastValidatedAt: now
            )
            modelContext.insert(row)
        }
        try modelContext.save()
    }

    /// Re-runs a live round-trip against the stored credentials.
    @MainActor
    func testConnection(_ connection: AIProviderConnection, modelContext: ModelContext) async throws {
        guard let provider = provider(for: connection) else { throw AIClassificationError.providerUnavailable }
        try await provider.validateConnection()
        connection.lastValidatedAt = Date()
        try? modelContext.save()
    }

    /// Disconnects: deletes the Keychain secret and marks the row `.disconnected`.
    /// There is no server-side revoke for an API key — the user must delete it in
    /// the provider console; the settings screen says so.
    @MainActor
    func disconnect(
        _ connection: AIProviderConnection,
        existing connections: [AIProviderConnection],
        modelContext: ModelContext
    ) throws {
        try? secretStore.delete(for: connection.provider.keychainAccount)
        connection.state = .disconnected
        connection.connectedAt = nil
        try modelContext.save()
    }

    private func makeProvider(_ kind: AIProviderKind, model: String, endpoint: URL) -> AIClassificationProvider {
        switch kind {
        case .openAI:
            OpenAIClassificationProvider(endpoint: endpoint, model: model, secretStore: secretStore, transport: transport)
        case .anthropic:
            AnthropicClassificationProvider(endpoint: endpoint, model: model, secretStore: secretStore, transport: transport)
        }
    }
}
