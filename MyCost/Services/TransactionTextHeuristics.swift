import Foundation

/// Stateless text-level parsing shared by the flat-line
/// ``TransactionCandidateParser`` and the spatial ``TransactionGrouper``:
/// amount extraction, date detection, status detection, merchant cleanup.
struct TransactionTextHeuristics {
    struct AmountMatch: Equatable {
        let value: Decimal
        let originalText: String
    }

    struct DateDetection: Equatable {
        let date: Date?
        let originalText: String?
        let confidence: Double
        let inferredYear: Bool
        let ambiguous: Bool

        static let none = DateDetection(
            date: nil, originalText: nil, confidence: 0, inferredYear: false, ambiguous: false
        )
    }

    private let calendar: Calendar
    private let referenceDate: Date

    init(calendar: Calendar = Calendar(identifier: .gregorian), referenceDate: Date = .now) {
        self.calendar = calendar
        self.referenceDate = referenceDate
    }

    // MARK: Amount

    func containsAmount(in text: String) -> Bool {
        !amountMatches(in: text).isEmpty
    }

    func amountMatches(in text: String) -> [AmountMatch] {
        let pattern = #"(?<![\d])[-+]?\(?\$?\s*\d{1,3}(?:,\d{3})*\.\d{2}\)?(?![\d])|(?<![\d])[-+]?\(?\$?\s*\d+\.\d{2}\)?(?![\d])"#
        return regexMatches(pattern, in: text).compactMap { match in
            let trimmed = match.trimmingCharacters(in: .whitespacesAndNewlines)
            let isParenthesized = trimmed.hasPrefix("(") && trimmed.hasSuffix(")")
            let isExplicitNegative = trimmed.hasPrefix("-")
            let isExplicitPositive = trimmed.hasPrefix("+")
            let numericText = trimmed
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
                .replacingOccurrences(of: "+", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: " ", with: "")

            guard var value = Decimal(string: numericText, locale: Locale(identifier: "en_US_POSIX")) else {
                return nil
            }

            if isParenthesized || isExplicitNegative || (!isExplicitPositive && isLikelyCredit(text)) {
                value = -value
            }

            return AmountMatch(value: value, originalText: match)
        }
    }

    func isLikelyCredit(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("refund") ||
            lowercased.contains("credit") ||
            lowercased.contains("cashback") ||
            lowercased.contains("payment thank you") ||
            lowercased.contains("payment - thank") ||
            lowercased.contains("paiement") ||
            lowercased.contains("merci")
    }

    // MARK: Status

    func detectStatus(in text: String) -> TransactionCandidateStatus? {
        let lowercased = text.lowercased()
        if lowercased.contains("pending") ||
            lowercased.contains("processing") ||
            lowercased.contains("authorization") ||
            lowercased.contains("temporary") {
            return .pending
        }

        if lowercased.contains("posted") ||
            lowercased.contains("cleared") ||
            lowercased.contains("completed") ||
            lowercased.contains("complete") {
            return .posted
        }

        return nil
    }

    // MARK: Date

    func detectDate(in text: String) -> DateDetection {
        for pattern in DatePattern.allCases {
            guard let match = firstMatch(pattern.regex, in: text) else { continue }
            guard let date = parseDate(match, pattern: pattern) else { continue }

            return DateDetection(
                date: date,
                originalText: match,
                confidence: pattern.hasYear ? 0.95 : 0.75,
                inferredYear: !pattern.hasYear,
                ambiguous: pattern.isNumericWithoutYear
            )
        }

        return .none
    }

    private func parseDate(_ text: String, pattern: DatePattern) -> Date? {
        let normalized = text
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch pattern {
        case .iso:
            return date(from: normalized, formats: ["yyyy-MM-dd"])
        case .numericWithYear:
            return date(from: normalized, formats: ["M/d/yyyy", "MM/dd/yyyy", "M/d/yy", "MM/dd/yy"])
        case .numericWithoutYear:
            return dateByInferringYear(monthDayText: normalized, formats: ["M/d", "MM/dd"])
        case .monthNameWithYear:
            return date(from: normalized, formats: ["MMM d yyyy", "MMMM d yyyy"])
        case .monthNameWithoutYear:
            return dateByInferringYear(monthDayText: normalized, formats: ["MMM d", "MMMM d"])
        }
    }

    private func date(from text: String, formats: [String]) -> Date? {
        for format in formats {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return calendar.startOfDay(for: date)
            }
        }
        return nil
    }

    private func dateByInferringYear(monthDayText: String, formats: [String]) -> Date? {
        let referenceYear = calendar.component(.year, from: referenceDate)

        for format in formats {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "\(format) yyyy"

            guard var date = formatter.date(from: "\(monthDayText) \(referenceYear)") else { continue }
            date = calendar.startOfDay(for: date)

            if let futureLimit = calendar.date(byAdding: .day, value: 31, to: referenceDate), date > futureLimit,
               let previousYear = calendar.date(byAdding: .year, value: -1, to: date) {
                return calendar.startOfDay(for: previousYear)
            }

            return date
        }

        return nil
    }

    // MARK: Merchant

    func cleanMerchantDescription(from text: String, removing fragments: [String]) -> String {
        var cleaned = text

        for fragment in fragments where !fragment.isEmpty {
            cleaned = cleaned.replacingOccurrences(of: fragment, with: " ")
        }

        for word in ["Pending", "Posted", "Cleared", "Completed", "Complete", "Processing", "Authorization", "Temporary"] {
            cleaned = cleaned.replacingOccurrences(of: word, with: " ", options: [.caseInsensitive])
        }

        for label in ["Card Purchase", "Debit Card Purchase", "Purchase", "Transaction"] {
            cleaned = cleaned.replacingOccurrences(of: label, with: " ", options: [.caseInsensitive])
        }

        return cleaned
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: Self.chevronAndBulletCharacters) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: Self.chevronAndBulletCharacters.union(.whitespaces))
    }

    static let chevronAndBulletCharacters = CharacterSet(charactersIn: "-*•·°:>‹›<»«")

    /// A line that is essentially just a date (a statement section header),
    /// returning the parsed date. Used to split regions and to carry the date
    /// forward to every transaction in the section.
    func dateOnlyHeader(in text: String) -> Date? {
        guard !containsAmount(in: text) else { return nil }
        let detection = detectDate(in: text)
        guard let date = detection.date, let original = detection.originalText else { return nil }
        let remainder = text
            .replacingOccurrences(of: original, with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-•·°:>‹›< ,"))
        return remainder.count <= 3 ? date : nil
    }

    /// True when the text has some content but no token that could plausibly be
    /// a merchant name — only currency codes, card-network words, or bare
    /// numbers/times. An empty string is *not* rejected here.
    func isNonMerchantText(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let ignored: Set<String> = [
            "CAD", "USD", "EUR", "GBP", "AUD", "MXN", "JPY",
            "VISA", "MASTERCARD", "AMEX", "DISCOVER", "INTERAC",
            "DEBIT", "CREDIT", "CARD", "ACCOUNT", "BALANCE"
        ]
        let meaningful = text
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",.:;")).uppercased() }
            .filter { token in
                guard token.count > 1, !ignored.contains(token) else { return false }
                return token.contains { $0.isLetter }
            }
        return meaningful.isEmpty
    }

    // MARK: Regex

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        regexMatches(pattern, in: text).first
    }

    private func regexMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
    }
}

private enum DatePattern: CaseIterable {
    case iso
    case numericWithYear
    case numericWithoutYear
    case monthNameWithYear
    case monthNameWithoutYear

    var regex: String {
        switch self {
        case .iso:
            #"\b\d{4}-\d{1,2}-\d{1,2}\b"#
        case .numericWithYear:
            #"\b\d{1,2}/\d{1,2}/(?:\d{2}|\d{4})\b"#
        case .numericWithoutYear:
            #"\b\d{1,2}/\d{1,2}\b"#
        case .monthNameWithYear:
            #"\b(?:Jan|January|Feb|February|Mar|March|Apr|April|May|Jun|June|Jul|July|Aug|August|Sep|Sept|September|Oct|October|Nov|November|Dec|December)\.?\s+\d{1,2},?\s+\d{4}\b"#
        case .monthNameWithoutYear:
            #"\b(?:Jan|January|Feb|February|Mar|March|Apr|April|May|Jun|June|Jul|July|Aug|August|Sep|Sept|September|Oct|October|Nov|November|Dec|December)\.?\s+\d{1,2}\b"#
        }
    }

    var hasYear: Bool {
        switch self {
        case .iso, .numericWithYear, .monthNameWithYear:
            true
        case .numericWithoutYear, .monthNameWithoutYear:
            false
        }
    }

    var isNumericWithoutYear: Bool {
        self == .numericWithoutYear
    }
}
