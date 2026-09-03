import CoreGraphics
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
    /// The spatial grouper could not confidently resolve the region (e.g. no
    /// clearly right-aligned amount, or conflicting amounts).
    case ambiguousLayout
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

/// One OCR observation kept verbatim on a candidate for debugging / the review
/// overlay: recognized text, its normalized frame (top-left origin, y down),
/// and the recognizer's confidence.
struct TransactionCandidateObservation: Codable, Equatable {
    var text: String
    var frame: CGRect
    var confidence: Double
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
    /// Present when the candidate came from spatial grouping.
    var observations: [TransactionCandidateObservation]
    /// Which screenshot in a batch produced this candidate — kept so the user
    /// can view the source image during review and so duplicates across
    /// overlapping screenshots can be traced.
    var sourceScreenshotID: UUID?

    init(
        id: UUID = UUID(),
        detectedDate: Date?,
        rawMerchantDescription: String,
        amount: Decimal?,
        status: TransactionCandidateStatus?,
        originalOCRText: String,
        sourceText: String,
        confidence: TransactionCandidateFieldConfidences,
        validationFlags: Set<TransactionCandidateValidationFlag>,
        observations: [TransactionCandidateObservation] = [],
        sourceScreenshotID: UUID? = nil
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
        self.observations = observations
        self.sourceScreenshotID = sourceScreenshotID
    }
}

/// Flat, line-oriented fallback parser. Used when spatial grouping is not
/// possible (no bounding boxes) or produced nothing. Spatial grouping via
/// ``TransactionRegionDetector`` + ``TransactionGrouper`` is the primary path.
struct TransactionCandidateParser {
    private let heuristics: TransactionTextHeuristics

    init(calendar: Calendar = Calendar(identifier: .gregorian), referenceDate: Date = .now) {
        self.heuristics = TransactionTextHeuristics(calendar: calendar, referenceDate: referenceDate)
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
            heuristics.dateOnlyHeader(in: line).map { (index, $0) }
        }
    }

    private func sectionDate(before index: Int, in headers: [(index: Int, date: Date)]) -> Date? {
        headers.last { $0.index <= index }?.date
    }

    private func candidateLineGroups(from lines: [String]) -> [(start: Int, end: Int)] {
        var ranges: [(start: Int, end: Int)] = []

        for (index, line) in lines.enumerated() {
            guard heuristics.containsAmount(in: line), !isLikelySummaryLine(line) else { continue }

            var startIndex = index
            var lookback = index - 1
            while lookback >= 0, index - lookback <= 3 {
                let previousLine = lines[lookback]
                if heuristics.containsAmount(in: previousLine) || isLikelySummaryLine(previousLine) || isNavigationLine(previousLine) {
                    break
                }

                startIndex = lookback
                if heuristics.detectDate(in: previousLine).date != nil {
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
                  !heuristics.containsAmount(in: line),
                  !isLikelySummaryLine(line),
                  !isNavigationLine(line),
                  heuristics.detectDate(in: line).date != nil || heuristics.detectStatus(in: line) != nil else {
                continue
            }

            var endIndex = index
            var lookahead = index + 1
            while lookahead < lines.count, lookahead - index <= 2 {
                let nextLine = lines[lookahead]
                if heuristics.containsAmount(in: nextLine) || isLikelySummaryLine(nextLine) || isNavigationLine(nextLine) {
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
        let amountMatches = heuristics.amountMatches(in: joinedText)
        let dateMatch = heuristics.detectDate(in: joinedText)
        let status = heuristics.detectStatus(in: joinedText)
        let removableFragments = (dateMatch.originalText.map { [$0] } ?? []) + amountMatches.map(\.originalText)

        var flags = Set<TransactionCandidateValidationFlag>()
        var confidence = TransactionCandidateFieldConfidences.empty

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

        let merchantDescription = heuristics.cleanMerchantDescription(
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

        if heuristics.isNonMerchantText(merchantDescription) {
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
        guard heuristics.detectStatus(in: lowercased) != nil else { return false }
        return !heuristics.containsAmount(in: lowercased) && heuristics.detectDate(in: lowercased).date == nil
    }
}
