import Foundation

/// Decides how one unresolved transaction should be categorized, in strict
/// priority order — **entirely deterministic and offline**:
///
/// 1. user ``MerchantRule``
/// 2. known merchant → category mapping (``LocalMerchantCategorizer``)
/// 3. manual — the caller leaves it Uncategorized
///
/// There is no network/AI tier. Nothing is applied silently by callers unless
/// they choose to: a `.ruleMatch` or `.localMatch` is a concrete answer the UI
/// can apply directly; `.unresolved` means "let the user pick".
struct MerchantCategorizationCoordinator {
    enum Outcome: Equatable {
        /// A user merchant rule matched.
        case ruleMatch(displayName: String, categoryName: String?, ruleID: UUID)
        /// The offline known-merchant table matched.
        case localMatch(displayName: String, categoryName: String)
        /// Nothing resolved it — categorize manually (→ Uncategorized).
        case unresolved
    }

    var ruleService: MerchantRuleService
    var localCategorizer: LocalMerchantCategorizer

    init(
        ruleService: MerchantRuleService = MerchantRuleService(),
        localCategorizer: LocalMerchantCategorizer = LocalMerchantCategorizer()
    ) {
        self.ruleService = ruleService
        self.localCategorizer = localCategorizer
    }

    func categorize(
        merchantDescription: String,
        rules: [MerchantRule],
        availableCategoryNames: [String]
    ) -> Outcome {
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
           let canonical = availableCategoryNames.first(where: {
               $0.compare(local.categoryName, options: .caseInsensitive) == .orderedSame
           }) {
            return .localMatch(displayName: local.normalizedMerchantName, categoryName: canonical)
        }

        // 3. Manual.
        return .unresolved
    }
}
