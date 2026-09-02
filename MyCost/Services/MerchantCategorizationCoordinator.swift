import Foundation

/// Decides how one unresolved transaction should be categorized, in strict
/// priority order:
///
/// 1. user ``MerchantRule`` (deterministic, no AI)
/// 2. local deterministic categorizer (``LocalMerchantCategorizer``, offline)
/// 3. connected AI provider (``AIClassificationProvider``), if any
/// 4. manual — the caller leaves it Uncategorized
///
/// AI is consulted only for transactions the first two tiers can't resolve, and
/// its result is never applied silently: a high-confidence answer is a
/// preselected *suggestion*, a low-confidence answer is flagged for review.
struct MerchantCategorizationCoordinator {
    enum Outcome: Equatable {
        /// A user merchant rule matched. No AI call.
        case ruleMatch(displayName: String, categoryName: String?, ruleID: UUID)
        /// The offline keyword categorizer matched. No AI call.
        case localMatch(displayName: String, categoryName: String)
        /// AI answered at or above the confidence threshold — show preselected.
        case aiSuggestion(MerchantClassification)
        /// AI answered below the threshold — show, clearly marked for review.
        case lowConfidence(MerchantClassification)
        /// Nothing resolved it. Categorize manually (→ Uncategorized).
        case unresolved(reason: UnresolvedReason)
    }

    enum UnresolvedReason: Equatable {
        case notConfigured
        case providerUnavailable
        case credentialsExpired
        case requestFailed(String)
        case invalidResponse(String)
    }

    static let defaultMinimumConfidence = 0.7

    var ruleService: MerchantRuleService
    var localCategorizer: LocalMerchantCategorizer
    var provider: AIClassificationProvider?
    var minimumConfidence: Double

    init(
        ruleService: MerchantRuleService = MerchantRuleService(),
        localCategorizer: LocalMerchantCategorizer = LocalMerchantCategorizer(),
        provider: AIClassificationProvider? = nil,
        minimumConfidence: Double = MerchantCategorizationCoordinator.defaultMinimumConfidence
    ) {
        self.ruleService = ruleService
        self.localCategorizer = localCategorizer
        self.provider = provider
        self.minimumConfidence = minimumConfidence
    }

    func categorize(
        merchantDescription: String,
        amount: Decimal?,
        rules: [MerchantRule],
        availableCategoryNames: [String]
    ) async -> Outcome {
        // 1. User rules win outright.
        if let rule = ruleService.bestRule(for: merchantDescription, rules: rules) {
            return .ruleMatch(
                displayName: rule.displayName,
                categoryName: rule.category?.name,
                ruleID: rule.id
            )
        }

        // 2. Offline keyword categorizer — only if the mapped category exists.
        if let local = localCategorizer.categorize(merchantDescription: merchantDescription),
           availableCategoryNames.contains(where: { $0.compare(local.categoryName, options: .caseInsensitive) == .orderedSame }) {
            let canonical = availableCategoryNames.first {
                $0.compare(local.categoryName, options: .caseInsensitive) == .orderedSame
            } ?? local.categoryName
            return .localMatch(displayName: local.normalizedMerchantName, categoryName: canonical)
        }

        // 3. AI fallback — only for what's still unresolved.
        guard let provider, provider.isConfigured else {
            return .unresolved(reason: .notConfigured)
        }

        do {
            let classification = try await provider.classify(
                MerchantClassificationRequest(
                    merchantDescription: merchantDescription,
                    amount: amount,
                    availableCategoryNames: availableCategoryNames
                )
            )
            return classification.confidence >= minimumConfidence
                ? .aiSuggestion(classification)
                : .lowConfidence(classification)
        } catch let error as AIClassificationError {
            return .unresolved(reason: reason(for: error))
        } catch is CancellationError {
            return .unresolved(reason: .requestFailed("Cancelled"))
        } catch {
            return .unresolved(reason: .requestFailed(error.localizedDescription))
        }
    }

    private func reason(for error: AIClassificationError) -> UnresolvedReason {
        switch error {
        case .notConfigured:
            return .notConfigured
        case .providerUnavailable:
            return .providerUnavailable
        case .credentialsExpired:
            return .credentialsExpired
        case .network(let message):
            return .requestFailed(message)
        case .invalidResponse(let message):
            return .invalidResponse(message)
        case .authenticationCancelled:
            return .requestFailed("Authentication cancelled")
        case .cancelled:
            return .requestFailed("Cancelled")
        }
    }
}
