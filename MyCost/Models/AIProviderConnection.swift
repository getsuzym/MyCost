import Foundation
import SwiftData

enum AIConnectionState: String, Codable, Sendable {
    case connected
    case disconnected
}

/// Persistent record of which AI provider the user has connected and how — but
/// **never** the secret itself. The API key / tokens live only in the Keychain
/// (``AISecretStore``); this model just carries identity, state, capabilities
/// and the endpoint/model configuration so the UI can render a Connected /
/// Disconnected experience without touching the Keychain.
@Model
final class AIProviderConnection {
    @Attribute(.unique) var id: UUID
    var providerRawValue: String
    var stateRawValue: String
    var displayName: String
    var authTypeRawValue: String
    var capabilityRawValues: [String]
    var model: String
    var endpointURL: URL
    var connectedAt: Date?
    var lastValidatedAt: Date?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        provider: AIProviderKind,
        state: AIConnectionState = .disconnected,
        authType: AIAuthType,
        model: String,
        endpointURL: URL,
        connectedAt: Date? = nil,
        lastValidatedAt: Date? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.providerRawValue = provider.rawValue
        self.stateRawValue = state.rawValue
        self.displayName = provider.displayName
        self.authTypeRawValue = authType.rawValue
        self.capabilityRawValues = provider.capabilities.map(\.rawValue)
        self.model = model
        self.endpointURL = endpointURL
        self.connectedAt = connectedAt
        self.lastValidatedAt = lastValidatedAt
        self.createdAt = createdAt
    }

    var provider: AIProviderKind {
        get { AIProviderKind(rawValue: providerRawValue) ?? .openAI }
        set {
            providerRawValue = newValue.rawValue
            displayName = newValue.displayName
            capabilityRawValues = newValue.capabilities.map(\.rawValue)
        }
    }

    var state: AIConnectionState {
        get { AIConnectionState(rawValue: stateRawValue) ?? .disconnected }
        set { stateRawValue = newValue.rawValue }
    }

    var authType: AIAuthType {
        get { AIAuthType(rawValue: authTypeRawValue) ?? .apiKey }
        set { authTypeRawValue = newValue.rawValue }
    }

    var capabilities: Set<AICapability> {
        Set(capabilityRawValues.compactMap(AICapability.init(rawValue:)))
    }

    var isConnected: Bool { state == .connected }
}
