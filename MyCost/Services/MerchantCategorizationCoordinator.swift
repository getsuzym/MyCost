import Foundation

/// Decides how a single unresolved transaction should be categorized.
///
/// Priority is always: deterministic ``MerchantRule`` first; the AI provider is
/// consulted *only* when no rule matches. A low-confidence AI answer, a missing
/// connection, or any failure all resolve to a manual outcome — the AI result
/// is never applied automatically.
struct MerchantCategorizationCoordinator {
    enum Outcome: Equatable {
        /// A deterministic merchant rule matched. The AI provider was not called.
        case ruleMatch(displayName: String, categoryName: String?, ruleID: UUID)
        /// AI answered at or above the confidence threshold. Needs user confirmation.
        case aiSuggestion(MerchantCategorizationSuggestion)
        /// AI answered below the threshold. Fall back to manual; offered only as a hint.
        case lowConfidence(MerchantCategorizationSuggestion)
        /// No rule, and AI could not help. Manual categorization.
        case unresolved(reason: UnresolvedReason)
    }

    enum UnresolvedReason: Equatable {
        case notConfigured
        case requestFailed(String)
        case invalidResponse(String)
    }

    /// AI suggestions below this confidence are returned as `.lowConfidence`
    /// and never surfaced as something the user can one-tap accept.
    static let defaultMinimumConfidence = 0.7

    var ruleService: MerchantRuleService
    var provider: MerchantCategorizationProviding
    var minimumConfidence: Double

    init(
        ruleService: MerchantRuleService = MerchantRuleService(),
        provider: MerchantCategorizationProviding,
        minimumConfidence: Double = MerchantCategorizationCoordinator.defaultMinimumConfidence
    ) {
        self.ruleService = ruleService
        self.provider = provider
        self.minimumConfidence = minimumConfidence
    }

    func categorize(
        merchantDescription: String,
        amount: Decimal?,
        rules: [MerchantRule],
        availableCategoryNames: [String]
    ) async -> Outcome {
        // 1. Deterministic rules win, and short-circuit before any AI call.
        if let rule = ruleService.bestRule(for: merchantDescription, rules: rules) {
            return .ruleMatch(
                displayName: rule.displayName,
                categoryName: rule.category?.name,
                ruleID: rule.id
            )
        }

        // 2. Only unresolved transactions reach the AI fallback.
        guard provider.isConfigured else {
            return .unresolved(reason: .notConfigured)
        }

        let request = MerchantCategorizationRequest(
            merchantDescription: merchantDescription,
            amount: amount,
            availableCategoryNames: availableCategoryNames
        )

        do {
            let suggestion = try await provider.suggestCategorization(for: request)
            return suggestion.confidence >= minimumConfidence
                ? .aiSuggestion(suggestion)
                : .lowConfidence(suggestion)
        } catch let error as MerchantCategorizationError {
            return .unresolved(reason: reason(for: error))
        } catch is CancellationError {
            return .unresolved(reason: .requestFailed("Cancelled"))
        } catch {
            return .unresolved(reason: .requestFailed(error.localizedDescription))
        }
    }

    private func reason(for error: MerchantCategorizationError) -> UnresolvedReason {
        switch error {
        case .notConfigured:
            return .notConfigured
        case .network(let message):
            return .requestFailed(message)
        case .invalidResponse(let message):
            return .invalidResponse(message)
        case .cancelled:
            return .requestFailed("Cancelled")
        }
    }
}
