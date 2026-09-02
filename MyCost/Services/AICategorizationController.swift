import Combine
import Foundation

/// App-level glue for the optional AI categorization feature: owns the user's
/// connection state and hands out a configured
/// ``MerchantCategorizationCoordinator``. Views observe `isConnected`; nothing
/// else in the app needs to know which provider is behind the protocol.
@MainActor
final class AICategorizationController: ObservableObject {
    @Published private(set) var connectionSummary: String?

    private let credentialStore: AICredentialStoring
    private let providerFactory: (AICredentialStoring) -> MerchantCategorizationProviding
    private let minimumConfidence: Double
    private(set) var provider: MerchantCategorizationProviding

    init(
        credentialStore: AICredentialStoring = KeychainAICredentialStore(),
        providerFactory: @escaping (AICredentialStoring) -> MerchantCategorizationProviding = {
            RemoteMerchantCategorizationProvider(credentialStore: $0)
        },
        minimumConfidence: Double = MerchantCategorizationCoordinator.defaultMinimumConfidence
    ) {
        self.credentialStore = credentialStore
        self.providerFactory = providerFactory
        self.minimumConfidence = minimumConfidence
        self.provider = providerFactory(credentialStore)
        refresh()
    }

    var isConnected: Bool { provider.isConfigured }

    func makeCoordinator() -> MerchantCategorizationCoordinator {
        MerchantCategorizationCoordinator(provider: provider, minimumConfidence: minimumConfidence)
    }

    func connect(endpointURL: URL, apiKey: String, model: String) throws {
        try credentialStore.save(
            AIProviderConnection(endpointURL: endpointURL, apiKey: apiKey, model: model)
        )
        provider = providerFactory(credentialStore)
        refresh()
    }

    func disconnect() throws {
        try credentialStore.clear()
        provider = providerFactory(credentialStore)
        refresh()
    }

    private func refresh() {
        connectionSummary = credentialStore.loadConnection().map { connection in
            let host = connection.endpointURL.host ?? connection.endpointURL.absoluteString
            return "\(connection.model) · \(host)"
        }
    }
}
