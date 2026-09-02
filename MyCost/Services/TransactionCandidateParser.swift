import Foundation

enum TransactionCandidateStatus: String, Codable, CaseIterable, Equatable {
    case pending
    case posted
}

enum TransactionCandidateValidationFlag: String, Codable, Hashable {
    case ambiguousDate
    case inferredYear
    case missingAmount
    case missingDate
    case missingMerchantDescription
    case missingStatus
    case multipleAmounts
    case possibleNonTransactionLine
}

struct TransactionCandidateFieldConfidences: Codable, Equatable {
    var date: Double
    var merchantDescription: Double
    var amount: Double
    var status: Double

    static let empty = TransactionCandidateFieldConfidences(
        date: 0,
        merchantDescription: 0,
        amount: 0,
        status: 0
    )
}

struct TransactionCandidate: Identifiable, Codable, Equatable {
    let id: UUID
    var detectedDate: Date?
    var rawMerchantDescription: String
    var amount: Decimal?
    var status: TransactionCandidateStatus?
    var originalOCRText: String
    var sourceText: String
    var confidence: TransactionCandidateFieldConfidences
    var validationFlags: Set<TransactionCandidateValidationFlag>

    init(
        id: UUID = UUID(),
        detectedDate: Date?,
        rawMerchantDescription: String,
        amount: Decimal?,
        status: TransactionCandidateStatus?,
        originalOCRText: String,
        sourceText: String,
        confidence: TransactionCandidateFieldConfidences,
        validationFlags: Set<TransactionCandidateValidationFlag>
    ) {
        self.id = id
        self.detectedDate = detectedDate
        self.rawMerchantDescription = rawMerchantDescription
        self.amount = amount
        self.status = status
        self.originalOCRText = originalOCRText
        self.sourceText = sourceText
        self.confidence = confidence
        self.validationFlags = validationFlags
    }
}

struct TransactionCandidateParser {
    private let calendar: Calendar
    private let referenceDate: Date

    init(calendar: Calendar = Calendar(identifier: .gregorian), referenceDate: Date = .now) {
        self.calendar = calendar
        self.referenceDate = referenceDate
    }

    func parse(ocrText: String) -> [TransactionCandidate] {
        parse(lines: ocrText.components(separatedBy: .newlines))
    }

    func parse(lines rawLines: [String]) -> [TransactionCandidate] {
        let originalOCRText = rawLines.joined(separator: "\n")
        let lines = rawLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return [] }

        let sectionDates = sectionDateHeaders(in: lines)

        return candidateLineGroups(from: lines).compactMap { group in
            parseCandidate(
                sourceLines: Array(lines[group.start...group.end]),
                fallbackDate: sectionDate(before: group.start, in: sectionDates),
                originalOCRText: originalOCRText
            )
        }
    }

    /// Many statement UIs print the date once as a section header and then list
    /// several transactions under it. This maps each line index to the date of
    /// the closest header at or above it, so every transaction in the section
    /// inherits it — not just the first one.
    private func sectionDateHeaders(in lines: [String]) -> [(index: Int, date: Date)] {
        lines.enumerated().compactMap { index, line in
            guard !containsAmount(in: line) else { return nil }
            let detection = detectDate(in: line)
            guard let date = detection.date, let original = detection.originalText else { return nil }
            // A header is a line that is essentially just the date.
            let remainder = line
                .replacingOccurrences(of: original, with: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "-•·°:>‹›< ,"))
            guard remainder.count <= 3 else { return nil }
            return (index, date)
        }
    }

    private func sectionDate(before index: Int, in headers: [(index: Int, date: Date)]) -> Date? {
        headers.last { $0.index <= index }?.date
    }

    private func candidateLineGroups(from lines: [String]) -> [(start: Int, end: Int)] {
        var ranges: [(start: Int, end: Int)] = []

        for (index, line) in lines.enumerated() {
            guard containsAmount(in: line), !isLikelySummaryLine(line) else { continue }

            var startIndex = index
            var lookback = index - 1
            while lookback >= 0, index - lookback <= 3 {
                let previousLine = lines[lookback]
                if containsAmount(in: previousLine) || isLikelySummaryLine(previousLine) || isNavigationLine(previousLine) {
                    break
                }

                startIndex = lookback
                if detectDate(in: previousLine).date != nil {
                    break
                }
                lookback -= 1
            }

            var endIndex = index
            if index + 1 < lines.count, isStatusOnlyLine(lines[index + 1]) {
                endIndex = index + 1
            }

            if !ranges.contains(where: { $0.start == startIndex && $0.end == endIndex }) {
                ranges.append((startIndex, endIndex))
            }
        }

        for (index, line) in lines.enumerated() {
            let isAlreadyGrouped = ranges.contains { range in
                index >= range.start && index <= range.end
            }
            guard !isAlreadyGrouped,
                  !containsAmount(in: line),
                  !isLikelySummaryLine(line),
                  !isNavigationLine(line),
                  detectDate(in: line).date != nil || detectStatus(in: line) != nil else {
                continue
            }

            var endIndex = index
            var lookahead = index + 1
            while lookahead < lines.count, lookahead - index <= 2 {
                let nextLine = lines[lookahead]
                if containsAmount(in: nextLine) || isLikelySummaryLine(nextLine) || isNavigationLine(nextLine) {
                    break
                }
                endIndex = lookahead
                lookahead += 1
            }

            ranges.append((index, endIndex))
        }

        return ranges.sorted { $0.start < $1.start }
    }

    private func parseCandidate(
        sourceLines: [String],
        fallbackDate: Date?,
        originalOCRText: String
    ) -> TransactionCandidate? {
        let sourceText = sourceLines.joined(separator: "\n")
        let joinedText = sourceLines.joined(separator: " ")
        let amountMatches = amountMatches(in: joinedText)
        let dateMatch = detectDate(in: joinedText)
        let status = detectStatus(in: joinedText)
        let removableFragments = (dateMatch.originalText.map { [$0] } ?? []) + amountMatches.map(\.originalText)

        var flags = Set<TransactionCandidateValidationFlag>()
        var confidence = TransactionCandidateFieldConfidences.empty

        // A date on the transaction's own line wins; otherwise fall back to the
        // section header date, if this group sits under one.
        let effectiveDate = dateMatch.date ?? fallbackDate
        let usedSectionDate = dateMatch.date == nil && fallbackDate != nil

        if effectiveDate == nil {
            flags.insert(.missingDate)
        } else if dateMatch.inferredYear {
            flags.insert(.inferredYear)
        }
        if dateMatch.ambiguous {
            flags.insert(.ambiguousDate)
        }
        confidence.date = dateMatch.date != nil ? dateMatch.confidence : (usedSectionDate ? 0.85 : 0)

        if status == nil {
            flags.insert(.missingStatus)
        }
        confidence.status = status == nil ? 0 : 0.95

        if amountMatches.isEmpty {
            flags.insert(.missingAmount)
        } else if amountMatches.count > 1 {
            flags.insert(.multipleAmounts)
        }
        let selectedAmount = amountMatches.last
        confidence.amount = amountMatches.isEmpty ? 0 : (amountMatches.count == 1 ? 0.95 : 0.65)

        let merchantDescription = cleanMerchantDescription(
            from: joinedText,
            removing: removableFragments
        )

        if merchantDescription.isEmpty {
            flags.insert(.missingMerchantDescription)
        }
        if isLikelySummaryLine(joinedText) || isNavigationLine(joinedText) {
            flags.insert(.possibleNonTransactionLine)
        }
        confidence.merchantDescription = merchantDescription.isEmpty ? 0 : 0.8

        // Drop rows that carry an amount but no real merchant — card balances
        // ("VISA / CAD 334.34"), status-bar noise, currency-code-only lines.
        if isNonMerchantText(merchantDescription) {
            return nil
        }

        guard selectedAmount != nil || effectiveDate != nil || !merchantDescription.isEmpty else {
            return nil
        }

        return TransactionCandidate(
            detectedDate: effectiveDate,
            rawMerchantDescription: merchantDescription,
            amount: selectedAmount?.value,
            status: status,
            originalOCRText: originalOCRText,
            sourceText: sourceText,
            confidence: confidence,
            validationFlags: flags
        )
    }

    private func detectStatus(in text: String) -> TransactionCandidateStatus? {
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

    private func detectDate(in text: String) -> DateDetection {
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

        return DateDetection(date: nil, originalText: nil, confidence: 0, inferredYear: false, ambiguous: false)
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

    private func containsAmount(in text: String) -> Bool {
        !amountMatches(in: text).isEmpty
    }

    private func amountMatches(in text: String) -> [AmountMatch] {
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

    private func cleanMerchantDescription(from text: String, removing fragments: [String]) -> String {
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
            .map { $0.trimmingCharacters(in: chevronAndBulletCharacters) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: chevronAndBulletCharacters.union(.whitespaces))
    }

    private var chevronAndBulletCharacters: CharacterSet {
        CharacterSet(charactersIn: "-*•·°:>‹›<»«")
    }

    /// True when the text has some content but no token that could plausibly be
    /// a merchant name — only currency codes, card-network words, or bare
    /// numbers/times. An empty string is *not* rejected here; that case is left
    /// to the missing-merchant flag and the caller's keep-for-review guard.
    private func isNonMerchantText(_ text: String) -> Bool {
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

    private func isLikelyCredit(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("refund") ||
            lowercased.contains("credit") ||
            lowercased.contains("cashback") ||
            lowercased.contains("payment thank you")
    }

    private func isLikelySummaryLine(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("available balance") ||
            lowercased.contains("current balance") ||
            lowercased.contains("statement balance") ||
            lowercased.contains("minimum payment") ||
            lowercased.contains("payment due") ||
            lowercased.contains("total balance") ||
            lowercased.contains("credit limit")
    }

    private func isNavigationLine(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased == "transactions" ||
            lowercased == "activity" ||
            lowercased == "recent activity" ||
            lowercased == "search" ||
            lowercased == "filter"
    }

    private func isStatusOnlyLine(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        guard detectStatus(in: lowercased) != nil else { return false }
        return !containsAmount(in: lowercased) && detectDate(in: lowercased).date == nil
    }

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

private struct AmountMatch {
    let value: Decimal
    let originalText: String
}

private struct DateDetection {
    let date: Date?
    let originalText: String?
    let confidence: Double
    let inferredYear: Bool
    let ambiguous: Bool
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
