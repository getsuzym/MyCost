import Foundation
import SwiftData

struct MerchantRuleApplication {
    let displayName: String
    let category: Category?
    let rule: MerchantRule

    var isRecurring: Bool { rule.isRecurring }
    var recurringFrequency: RecurrenceFrequency { rule.recurringFrequency }
    var ruleID: UUID { rule.id }
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

    /// Lowercased, whitespace-collapsed, trimmed — the form all match-type
    /// comparisons happen in.
    static func caseFolded(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct MerchantRuleService {
    // MARK: Matching

    /// Whether `rule` matches a transaction with the given merchant name and
    /// original description. Case-insensitive, whitespace-normalized, tested
    /// against **both** fields. `.exact` rules also honor the legacy
    /// processor-noise-stripped key and token-subset match so pre-existing
    /// rules keep working.
    func matches(_ rule: MerchantRule, merchantName: String, originalDescription: String) -> Bool {
        specificity(of: rule, merchantName: merchantName, originalDescription: originalDescription) != nil
    }

    /// A higher number = a more specific match; `nil` = no match.
    private func specificity(of rule: MerchantRule, merchantName: String, originalDescription: String) -> Int? {
        let needle = MerchantRuleNormalizer.caseFolded(rule.matchText)
        guard !needle.isEmpty else { return nil }

        let haystacks = [
            MerchantRuleNormalizer.caseFolded(merchantName),
            MerchantRuleNormalizer.caseFolded(originalDescription)
        ].filter { !$0.isEmpty }

        switch rule.matchType {
        case .exact:
            if haystacks.contains(where: { $0 == needle }) { return MerchantRuleMatchType.exact.specificityRank }
        case .startsWith:
            if haystacks.contains(where: { $0.hasPrefix(needle) }) { return MerchantRuleMatchType.startsWith.specificityRank }
        case .endsWith:
            if haystacks.contains(where: { $0.hasSuffix(needle) }) { return MerchantRuleMatchType.endsWith.specificityRank }
        case .contains:
            if haystacks.contains(where: { $0.contains(needle) }) { return MerchantRuleMatchType.contains.specificityRank }
        }

        // Legacy fallback for `.exact` rules only (normalized-key equality or a
        // ≥2-token subset), preserving pre-match-type behavior.
        guard rule.matchType == .exact else { return nil }

        let ruleKey = rule.normalizedMatchText.isEmpty
            ? MerchantRuleNormalizer.normalizedMerchantKey(for: rule.matchText)
            : rule.normalizedMatchText
        guard !ruleKey.isEmpty else { return nil }

        for source in [originalDescription, merchantName] where !source.isEmpty {
            let descriptionKey = MerchantRuleNormalizer.normalizedMerchantKey(for: source)
            guard !descriptionKey.isEmpty else { continue }
            if descriptionKey == ruleKey { return MerchantRuleMatchType.exact.specificityRank }
            let descriptionTokens = Set(descriptionKey.split(separator: " ").map(String.init))
            let ruleTokens = Set(ruleKey.split(separator: " ").map(String.init))
            if ruleTokens.count >= 2, ruleTokens.isSubset(of: descriptionTokens) {
                return MerchantRuleMatchType.startsWith.specificityRank // "as specific as prefix"
            }
        }
        return nil
    }

    /// The winning rule for a transaction. Conflict order:
    /// **priority** (higher wins outright) → match specificity (exact >
    /// starts/ends > contains) → longer `matchText` → most recently updated.
    func bestRule(for merchantName: String, originalDescription: String, rules: [MerchantRule]) -> MerchantRule? {
        rules
            .filter(\.isEnabled)
            .compactMap { rule -> (rule: MerchantRule, specificity: Int)? in
                guard let s = specificity(of: rule, merchantName: merchantName, originalDescription: originalDescription) else { return nil }
                return (rule, s)
            }
            .sorted { lhs, rhs in
                if lhs.rule.priority != rhs.rule.priority { return lhs.rule.priority > rhs.rule.priority }
                if lhs.specificity != rhs.specificity { return lhs.specificity > rhs.specificity }
                let lhsLen = MerchantRuleNormalizer.caseFolded(lhs.rule.matchText).count
                let rhsLen = MerchantRuleNormalizer.caseFolded(rhs.rule.matchText).count
                if lhsLen != rhsLen { return lhsLen > rhsLen }
                return lhs.rule.updatedAt > rhs.rule.updatedAt
            }
            .first?
            .rule
    }

    /// Convenience for callers that only have one text field.
    func bestRule(for rawDescription: String, rules: [MerchantRule]) -> MerchantRule? {
        bestRule(for: rawDescription, originalDescription: rawDescription, rules: rules)
    }

    func application(for merchantName: String, originalDescription: String, rules: [MerchantRule]) -> MerchantRuleApplication? {
        guard let rule = bestRule(for: merchantName, originalDescription: originalDescription, rules: rules) else { return nil }
        return MerchantRuleApplication(displayName: rule.displayName, category: rule.category, rule: rule)
    }

    func application(for rawDescription: String, rules: [MerchantRule]) -> MerchantRuleApplication? {
        application(for: rawDescription, originalDescription: rawDescription, rules: rules)
    }

    func applyRules(to transaction: Transaction, rules: [MerchantRule]) {
        guard let application = application(
            for: transaction.merchantName,
            originalDescription: transaction.originalDescription,
            rules: rules
        ) else { return }
        transaction.merchantName = application.displayName
        if let category = application.category {
            transaction.category = category
        }
        // Recurring rules mark the transaction recurring; a non-recurring rule
        // never clears an existing recurring flag.
        if application.isRecurring {
            transaction.isRecurring = true
        }
        transaction.updatedAt = .now
    }

    // MARK: Learning

    @MainActor
    func rememberRule(
        matchText: String,
        displayName: String,
        category: Category?,
        matchType: MerchantRuleMatchType = .contains,
        priority: Int = 0,
        isRecurring: Bool = false,
        recurringFrequency: RecurrenceFrequency = .monthly,
        modelContext: ModelContext,
        saveImmediately: Bool = true
    ) {
        _ = learnRule(
            matchText: matchText,
            displayName: displayName,
            category: category,
            matchType: matchType,
            priority: priority,
            isRecurring: isRecurring,
            recurringFrequency: recurringFrequency,
            existingRules: [],
            modelContext: modelContext,
            saveImmediately: saveImmediately
        )
    }

    /// Create-or-update: if a rule with the same `matchText` + `matchType`
    /// already exists it's updated in place (no duplicates); otherwise a new
    /// rule is inserted. Returns the affected rule, or `nil` on unusable input.
    @MainActor
    @discardableResult
    func learnRule(
        matchText: String,
        displayName: String,
        category: Category?,
        matchType: MerchantRuleMatchType = .contains,
        priority: Int = 0,
        isRecurring: Bool = false,
        recurringFrequency: RecurrenceFrequency = .monthly,
        existingRules: [MerchantRule],
        modelContext: ModelContext,
        saveImmediately: Bool = true
    ) -> MerchantRule? {
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMatchText = matchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = MerchantRuleNormalizer.caseFolded(trimmedMatchText)
        guard !trimmedDisplayName.isEmpty, folded.count >= matchType.minimumMatchTextLength else { return nil }

        let normalizedMatchText = MerchantRuleNormalizer.normalizedMerchantKey(for: trimmedMatchText)

        let match = existingRules.first { rule in
            rule.matchType == matchType &&
                MerchantRuleNormalizer.caseFolded(rule.matchText) == folded
        }

        if let match {
            match.matchText = trimmedMatchText
            match.normalizedMatchText = normalizedMatchText
            match.displayName = trimmedDisplayName
            match.matchType = matchType
            if priority != 0 { match.priority = priority }
            if let category { match.category = category }
            // Turning recurring on sticks; we don't silently turn it off.
            if isRecurring {
                match.isRecurring = true
                match.recurringFrequency = recurringFrequency
            }
            match.isEnabled = true
            match.updatedAt = .now
            if saveImmediately { try? modelContext.save() }
            return match
        }

        let rule = MerchantRule(
            matchText: trimmedMatchText,
            normalizedMatchText: normalizedMatchText,
            displayName: trimmedDisplayName,
            matchType: matchType,
            priority: priority,
            isRecurring: isRecurring,
            recurringFrequency: recurringFrequency,
            category: category
        )
        modelContext.insert(rule)
        if saveImmediately { try? modelContext.save() }
        return rule
    }

    @MainActor
    func updateRule(
        _ rule: MerchantRule,
        matchText: String,
        displayName: String,
        matchType: MerchantRuleMatchType,
        priority: Int,
        isRecurring: Bool,
        recurringFrequency: RecurrenceFrequency,
        category: Category?,
        isEnabled: Bool
    ) {
        rule.matchText = matchText.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.normalizedMatchText = MerchantRuleNormalizer.normalizedMerchantKey(for: rule.matchText)
        rule.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.matchType = matchType
        rule.priority = priority
        rule.isRecurring = isRecurring
        rule.recurringFrequency = recurringFrequency
        rule.category = category
        rule.isEnabled = isEnabled
        rule.updatedAt = .now
    }

    @MainActor
    func applyRuleToExistingTransactions(rule: MerchantRule, transactions: [Transaction]) {
        guard rule.isEnabled else { return }
        for transaction in transactions {
            _ = attach(rule: rule, to: transaction, requireMatch: true)
        }
    }

    /// Attach one specific rule to one transaction (the "pick an existing rule"
    /// flow). When `requireMatch` is true the rule's `matchText` must actually
    /// match the transaction (name or original description) or nothing changes.
    /// Returns whether the rule was applied.
    @MainActor
    @discardableResult
    func attach(rule: MerchantRule, to transaction: Transaction, requireMatch: Bool = true) -> Bool {
        if requireMatch {
            guard matches(
                rule,
                merchantName: transaction.merchantName,
                originalDescription: transaction.originalDescription
            ) else { return false }
        }
        transaction.merchantName = rule.displayName
        if let category = rule.category {
            transaction.category = category
        }
        // Recurring rules mark the transaction recurring; never clear the flag.
        if rule.isRecurring {
            transaction.isRecurring = true
        }
        transaction.updatedAt = .now
        return true
    }

    /// Enabled rules whose `matchText` matches the transaction — the candidates
    /// for "attach an existing rule". Checks **both** the (possibly hand-edited)
    /// merchant name and the bank's original description, so a rule learned from
    /// the raw bank text still matches after the name was cleaned up.
    func rulesMatching(merchantName: String, originalDescription: String, in rules: [MerchantRule]) -> [MerchantRule] {
        rules.filter { rule in
            rule.isEnabled && matches(rule, merchantName: merchantName, originalDescription: originalDescription)
        }
    }

    func rulesMatching(_ description: String, in rules: [MerchantRule]) -> [MerchantRule] {
        rulesMatching(merchantName: description, originalDescription: description, in: rules)
    }
}

extension Sequence where Element == MerchantRule {
    /// Localized, case-insensitive alphabetical order by normalized merchant
    /// name — the browsing order for the Merchant Rules list and the
    /// "attach existing rule" picker. Conflict resolution still uses `priority`.
    func alphabetizedByName() -> [MerchantRule] {
        sorted {
            $0.normalizedMerchantName.localizedCaseInsensitiveCompare($1.normalizedMerchantName) == .orderedAscending
        }
    }
}
