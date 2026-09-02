import Foundation

/// Minimal, provider-agnostic input for an AI categorization request.
///
/// Only merchant text and (optionally) the amount are ever sent to an AI
/// service. No dates, account names, notes, balances, running totals, or any
/// other financial data are included. `availableCategoryNames` is the fixed
/// label space the model must choose from — it contains only the user's
/// category names (e.g. "Groceries"), never transaction data.
struct MerchantCategorizationRequest: Equatable {
    let merchantDescription: String
    let amount: Decimal?
    let availableCategoryNames: [String]

    init(merchantDescription: String, amount: Decimal? = nil, availableCategoryNames: [String] = []) {
        self.merchantDescription = merchantDescription
        self.amount = amount
        self.availableCategoryNames = availableCategoryNames
    }
}

/// A single AI categorization result. `categoryName`, when non-nil, is
/// guaranteed to match one of the request's `availableCategoryNames`
/// (case-insensitively, returned in the canonical casing). `confidence` is
/// clamped to `0...1`.
struct MerchantCategorizationSuggestion: Equatable {
    let normalizedMerchantName: String
    let categoryName: String?
    let confidence: Double
}

enum MerchantCategorizationError: Error, Equatable {
    /// The end user has not connected an AI service/account.
    case notConfigured
    /// The request could not be completed (offline, timeout, HTTP error…).
    case network(String)
    /// A response came back but could not be understood or trusted.
    case invalidResponse(String)
    /// The request was cancelled before completing.
    case cancelled
}

/// The single seam every AI categorization backend is reached through. Swap the
/// concrete type, or use ``DisabledMerchantCategorizationProvider`` to turn the
/// feature off, without touching callers.
protocol MerchantCategorizationProviding: Sendable {
    /// `true` only when the end user has connected their own AI account and a
    /// request could plausibly be attempted.
    var isConfigured: Bool { get }

    func suggestCategorization(
        for request: MerchantCategorizationRequest
    ) async throws -> MerchantCategorizationSuggestion
}

/// Default provider when nothing is connected: always unconfigured, always
/// fails with `.notConfigured`. Keeps the rest of the app AI-agnostic.
struct DisabledMerchantCategorizationProvider: MerchantCategorizationProviding {
    var isConfigured: Bool { false }

    func suggestCategorization(
        for request: MerchantCategorizationRequest
    ) async throws -> MerchantCategorizationSuggestion {
        throw MerchantCategorizationError.notConfigured
    }
}
