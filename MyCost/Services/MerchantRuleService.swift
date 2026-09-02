import Foundation
import SwiftData

struct MerchantRuleApplication {
    let displayName: String
    let category: Category?
    let rule: MerchantRule
}

enum MerchantRuleNormalizer {
    static func normalizedMerchantKey(for text: String) -> String {
        let uppercased = text.uppercased()
        var working = uppercased
            .replacingOccurrences(of: #"SQ\s*\*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"PAYPAL\s*\*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"PP\s*\*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"AMZN\s+MKT[P]?|AMAZON\.COM|AMAZON MKTPLACE"#, with: " AMAZON ", options: .regularExpression)
            .replacingOccurrences(of: #"TST\s*\*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"CHECKCARD|DEBIT CARD|CARD PURCHASE|PURCHASE AUTHORIZED ON|RECURRING PAYMENT|ONLINE PAYMENT"#, with: " ", options: .regularExpression)

        working = working.replacingOccurrences(of: #"#[0-9A-Z-]{3,}"#, with: " ", options: .regularExpression)
        working = working.replacingOccurrences(of: #"\b(?:STORE|ST|LOCATION|LOC|TERM|TERMINAL|REF|AUTH|ID|POS|TRACE|APPR|INV|ORDER)\s*[:#-]?\s*[0-9A-Z-]{2,}\b"#, with: " ", options: .regularExpression)
        working = working.replacingOccurrences(of: #"\b[0-9]{3,}\b"#, with: " ", options: .regularExpression)
        working = working.replacingOccurrences(of: #"\b[A-Z]{2}\b\s+\d{5}(?:-\d{4})?\b"#, with: " ", options: .regularExpression)

        let tokens = working
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { token in
                !token.isEmpty &&
                    !ignoredTokens.contains(token) &&
                    !isLikelyReferenceToken(token)
            }

        return tokens.joined(separator: " ")
    }

    private static let ignoredTokens: Set<String> = [
        "THE", "INC", "LLC", "LTD", "CO", "COMPANY", "CORP", "CORPORATION",
        "STORE", "STORES", "MARKETPLACE", "MKTPLACE", "MKT", "PAYMENT", "PURCHASE",
        "POS", "VISA", "MASTERCARD", "CARD", "DEBIT", "CREDIT", "AUTH", "REF",
        "US", "USA", "WWW", "COM"
    ]

    private static func isLikelyReferenceToken(_ token: String) -> Bool {
        guard token.count >= 5 else { return false }
        let scalars = token.unicodeScalars
        let digitCount = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        return digitCount >= 3
    }
}

struct MerchantRuleService {
    func bestRule(for rawDescription: String, rules: [MerchantRule]) -> MerchantRule? {
        let normalizedDescription = MerchantRuleNormalizer.normalizedMerchantKey(for: rawDescription)
        guard !normalizedDescription.isEmpty else { return nil }

        return rules
            .filter(\.isEnabled)
            .compactMap { rule -> (rule: MerchantRule, score: Int)? in
                let normalizedRule = rule.normalizedMatchText.isEmpty
                    ? MerchantRuleNormalizer.normalizedMerchantKey(for: rule.matchText)
                    : rule.normalizedMatchText
                guard !normalizedRule.isEmpty else { return nil }

                if normalizedDescription == normalizedRule {
                    return (rule, 3)
                }

                let descriptionTokens = Set(normalizedDescription.split(separator: " ").map(String.init))
                let ruleTokens = Set(normalizedRule.split(separator: " ").map(String.init))
                guard ruleTokens.count >= 2 else { return nil }

                if ruleTokens.isSubset(of: descriptionTokens) {
                    return (rule, 2)
                }

                return nil
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                if lhs.rule.normalizedMatchText.count != rhs.rule.normalizedMatchText.count {
                    return lhs.rule.normalizedMatchText.count > rhs.rule.normalizedMatchText.count
                }
                return lhs.rule.updatedAt > rhs.rule.updatedAt
            }
            .first?
            .rule
    }

    func application(for rawDescription: String, rules: [MerchantRule]) -> MerchantRuleApplication? {
        guard let rule = bestRule(for: rawDescription, rules: rules) else { return nil }
        return MerchantRuleApplication(displayName: rule.displayName, category: rule.category, rule: rule)
    }

    func applyRules(to transaction: Transaction, rules: [MerchantRule]) {
        let sourceText = transaction.originalDescription.isEmpty ? transaction.merchantName : transaction.originalDescription
        guard let application = application(for: sourceText, rules: rules) else { return }
        transaction.merchantName = application.displayName
        if let category = application.category {
            transaction.category = category
        }
        transaction.updatedAt = .now
    }

    @MainActor
    func rememberRule(
        matchText: String,
        displayName: String,
        category: Category?,
        modelContext: ModelContext,
        saveImmediately: Bool = true
    ) {
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMatchText = matchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMatchText = MerchantRuleNormalizer.normalizedMerchantKey(for: trimmedMatchText)
        guard !trimmedDisplayName.isEmpty, !normalizedMatchText.isEmpty else { return }

        let rule = MerchantRule(
            matchText: trimmedMatchText,
            normalizedMatchText: normalizedMatchText,
            displayName: trimmedDisplayName,
            category: category
        )
        modelContext.insert(rule)
        if saveImmediately {
            try? modelContext.save()
        }
    }

    /// Create-or-update used when the user confirms/corrects an AI suggestion:
    /// if a rule with the same normalized key already exists it is updated in
    /// place (so we never accumulate duplicates), otherwise a new rule is
    /// inserted. Similar future transactions then resolve locally with no AI
    /// call. Returns the affected rule, or `nil` if the input was unusable.
    @MainActor
    @discardableResult
    func learnRule(
        matchText: String,
        displayName: String,
        category: Category?,
        existingRules: [MerchantRule],
        modelContext: ModelContext,
        saveImmediately: Bool = true
    ) -> MerchantRule? {
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMatchText = matchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMatchText = MerchantRuleNormalizer.normalizedMerchantKey(for: trimmedMatchText)
        guard !trimmedDisplayName.isEmpty, !normalizedMatchText.isEmpty else { return nil }

        let match = existingRules.first { rule in
            let ruleKey = rule.normalizedMatchText.isEmpty
                ? MerchantRuleNormalizer.normalizedMerchantKey(for: rule.matchText)
                : rule.normalizedMatchText
            return ruleKey == normalizedMatchText
        }

        if let match {
            match.matchText = trimmedMatchText
            match.normalizedMatchText = normalizedMatchText
            match.displayName = trimmedDisplayName
            if let category {
                match.category = category
            }
            match.isEnabled = true
            match.updatedAt = .now
            if saveImmediately {
                try? modelContext.save()
            }
            return match
        }

        let rule = MerchantRule(
            matchText: trimmedMatchText,
            normalizedMatchText: normalizedMatchText,
            displayName: trimmedDisplayName,
            category: category
        )
        modelContext.insert(rule)
        if saveImmediately {
            try? modelContext.save()
        }
        return rule
    }

    @MainActor
    func updateRule(_ rule: MerchantRule, matchText: String, displayName: String, category: Category?, isEnabled: Bool) {
        rule.matchText = matchText.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.normalizedMatchText = MerchantRuleNormalizer.normalizedMerchantKey(for: rule.matchText)
        rule.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.category = category
        rule.isEnabled = isEnabled
        rule.updatedAt = .now
    }

    @MainActor
    func applyRuleToExistingTransactions(
        rule: MerchantRule,
        transactions: [Transaction]
    ) {
        guard rule.isEnabled else { return }

        for transaction in transactions {
            let sourceText = transaction.originalDescription.isEmpty ? transaction.merchantName : transaction.originalDescription
            guard bestRule(for: sourceText, rules: [rule])?.id == rule.id else { continue }
            transaction.merchantName = rule.displayName
            if let category = rule.category {
                transaction.category = category
            }
            transaction.updatedAt = .now
        }
    }
}
