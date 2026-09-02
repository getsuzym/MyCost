import Foundation

// MARK: - Provider identity

/// The AI vendors MyCost can talk to. Categorization is written against
/// ``AIClassificationProvider``, never a concrete vendor, so more can be added
/// (or all removed) without touching callers.
enum AIProviderKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case openAI
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: "ChatGPT (OpenAI)"
        case .anthropic: "Claude (Anthropic)"
        }
    }

    /// Where the user creates the key this app will use.
    var consoleURL: URL {
        switch self {
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        }
    }

    var defaultEndpoint: URL {
        switch self {
        case .openAI: URL(string: "https://api.openai.com/v1/chat/completions")!
        case .anthropic: URL(string: "https://api.anthropic.com/v1/messages")!
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: "gpt-4o-mini"
        case .anthropic: "claude-haiku-4-5"
        }
    }

    /// Officially supported authentication for a third-party iOS app to obtain
    /// **model/API** access on the user's own billing.
    ///
    /// As of this writing neither vendor offers OAuth / "connect your account"
    /// that grants Chat Completions / Messages access to third-party apps —
    /// consumer ChatGPT Plus and Claude Pro logins provide identity only, not
    /// API authorization or billing. So the only supported mechanism is the
    /// user's own API key, entered as an advanced setting. If a vendor ships a
    /// real OAuth grant later, add `.oauth` here and a concrete flow.
    var supportedAuthTypes: [AIAuthType] {
        [.apiKey]
    }

    var capabilities: Set<AICapability> {
        [.merchantCategorization]
    }

    /// Keychain account string for this provider's secret.
    var keychainAccount: String { "ai-provider.\(rawValue)" }
}

enum AIAuthType: String, Codable, Sendable {
    /// User-supplied API key, stored in Keychain.
    case apiKey
    /// Reserved for a future official OAuth grant (ASWebAuthenticationSession +
    /// PKCE + refresh). Not currently offered by either vendor.
    case oauth
}

enum AICapability: String, Codable, Sendable {
    case merchantCategorization
}

// MARK: - Request / response

/// The *only* transaction information that leaves the device for classification:
/// the merchant description and, optionally, the amount, plus the user's own
/// category names as the label space. Structurally cannot carry screenshots,
/// account numbers, other transactions, or statements.
struct MerchantClassificationRequest: Equatable {
    let merchantDescription: String
    let amount: Decimal?
    let availableCategoryNames: [String]

    init(merchantDescription: String, amount: Decimal? = nil, availableCategoryNames: [String] = []) {
        self.merchantDescription = merchantDescription
        self.amount = amount
        self.availableCategoryNames = availableCategoryNames
    }
}

/// The strict structured result a provider must return. `suggestedCategory`, if
/// non-nil, is guaranteed to be one of the request's `availableCategoryNames`
/// (canonical casing). `confidence` is clamped to `0...1`.
struct MerchantClassification: Equatable {
    let normalizedMerchantName: String
    let suggestedCategory: String?
    let confidence: Double
    let reasoningSummary: String?
}

enum AIClassificationError: Error, Equatable {
    /// No provider is connected.
    case notConfigured
    /// A provider is selected but its stored credentials are missing/removed.
    case providerUnavailable
    /// Credentials are present but rejected (401/403) — reconnect needed.
    case credentialsExpired
    /// The user cancelled an interactive auth step.
    case authenticationCancelled
    /// Transport failure (offline, timeout, 5xx, rate limit…).
    case network(String)
    /// A response came back but could not be understood or trusted.
    case invalidResponse(String)
    case cancelled
}

// MARK: - The seam

protocol AIClassificationProvider: Sendable {
    var kind: AIProviderKind { get }
    /// `true` when a usable credential for this provider is available.
    var isConfigured: Bool { get }

    /// Lightweight round-trip used by the settings screen's "Test Connection".
    func validateConnection() async throws

    func classify(_ request: MerchantClassificationRequest) async throws -> MerchantClassification
}
