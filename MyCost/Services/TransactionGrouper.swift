import CoreGraphics
import Foundation

/// Turns spatially-detected ``TransactionRegion``s into ``TransactionCandidate``s.
///
/// Field assignment is position-driven, not OCR-order-driven:
/// - the amount is taken from **right-aligned** currency text,
/// - the merchant/description from the **left-side** text (all rows, so
///   multi-line descriptions survive),
/// - dates and status labels from anywhere in the region, falling back to the
///   nearest date-only section header above.
///
/// When a region has no clearly right-aligned amount, or has conflicting
/// amounts, the candidate is marked uncertain (`.ambiguousLayout`,
/// `.multipleAmounts`) rather than guessing.
struct TransactionGrouper {
    struct Configuration: Equatable {
        /// An amount observation counts as right-aligned if its horizontal
        /// center is past this fraction of the region width, or its right edge
        /// is within `rightEdgeSlack` of the region's right edge.
        var rightHalfThreshold: CGFloat = 0.55
        var rightEdgeSlack: CGFloat = 0.08
        /// Merchant text is taken from observations whose center is left of this
        /// fraction (plus the top row regardless of position).
        var leftZoneThreshold: CGFloat = 0.65

        static let `default` = Configuration()
    }

    private let heuristics: TransactionTextHeuristics
    private let configuration: Configuration

    init(
        calendar: Calendar = Calendar(identifier: .gregorian),
        referenceDate: Date = .now,
        configuration: Configuration = .default
    ) {
        self.heuristics = TransactionTextHeuristics(calendar: calendar, referenceDate: referenceDate)
        self.configuration = configuration
    }

    func candidates(from regions: [TransactionRegion], originalOCRText: String) -> [TransactionCandidate] {
        var result: [TransactionCandidate] = []
        var carriedSectionDate: Date?

        // Anything above the first date section header is account chrome
        // (card name, balance, filter tabs), not the transaction list.
        let firstHeaderIndex = regions.firstIndex { heuristics.dateOnlyHeader(in: $0.text) != nil }

        for (index, region) in regions.enumerated() {
            let outcome = interpret(region: region, sectionDate: carriedSectionDate, originalOCRText: originalOCRText)
            switch outcome {
            case .sectionHeader(let date):
                carriedSectionDate = date
            case .candidate(let candidate):
                if let firstHeaderIndex, index < firstHeaderIndex { continue }
                result.append(candidate)
            case .ignored:
                break
            }
        }

        return result
    }

    private enum RegionOutcome {
        case candidate(TransactionCandidate)
        case sectionHeader(Date)
        case ignored
    }

    private func interpret(
        region: TransactionRegion,
        sectionDate: Date?,
        originalOCRText: String
    ) -> RegionOutcome {
        let observations = region.observations
        guard !observations.isEmpty else { return .ignored }

        let regionText = observations.map(\.text).joined(separator: " ")
        let bounds = region.frame

        var flags = Set<TransactionCandidateValidationFlag>()
        var confidence = TransactionCandidateFieldConfidences.empty

        // MARK: Amount — from right-aligned currency text
        let amountObservations: [(observation: OCRTextObservation, value: Decimal, text: String)] =
            observations.flatMap { observation in
                heuristics.amountMatches(in: observation.text).map { (observation, $0.value, $0.originalText) }
            }
        let rightAligned = amountObservations.filter { isRightAligned($0.observation, in: bounds) }

        var amount: Decimal?
        if !rightAligned.isEmpty {
            let distinctValues = Set(rightAligned.map(\.value))
            if distinctValues.count == 1 {
                amount = rightAligned[0].value
                confidence.amount = rightAligned.count == 1 ? 0.95 : 0.85
            } else {
                // Conflicting right-aligned amounts: do not guess.
                flags.insert(.multipleAmounts)
                flags.insert(.ambiguousLayout)
                confidence.amount = 0.2
            }
        } else if let anyAmount = amountObservations.last {
            // An amount exists but not where we expect it — surface it, flagged.
            amount = anyAmount.value
            flags.insert(.ambiguousLayout)
            confidence.amount = 0.5
        } else {
            flags.insert(.missingAmount)
        }
        if amountObservations.count > rightAligned.count, rightAligned.count == 1 {
            flags.insert(.multipleAmounts)
        }

        // MARK: Date / status
        let dateMatch = heuristics.detectDate(in: regionText)
        let effectiveDate = dateMatch.date ?? sectionDate
        if effectiveDate == nil {
            flags.insert(.missingDate)
        } else if dateMatch.date == nil {
            confidence.date = 0.85
        } else {
            confidence.date = dateMatch.confidence
            if dateMatch.inferredYear { flags.insert(.inferredYear) }
            if dateMatch.ambiguous { flags.insert(.ambiguousDate) }
        }

        let status = heuristics.detectStatus(in: regionText)
        if status == nil { flags.insert(.missingStatus) }
        confidence.status = status == nil ? 0 : 0.95

        // MARK: Merchant — left-side text of each row, dropping detail rows
        // ("City, PROV", "Pay in Installments") that follow the first row so a
        // wrapped merchant name survives but the address/tag lines don't.
        let amountTexts = Set(amountObservations.map(\.text))
        var merchantRows: [String] = []
        for (lineIndex, textLine) in region.lines.enumerated() {
            let leftText = textLine.observations
                .filter { observation in
                    !amountTexts.contains(observation.text)
                        && centerXFraction(observation, in: bounds) <= configuration.leftZoneThreshold
                }
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !leftText.isEmpty else { continue }
            if lineIndex > 0, heuristics.isDetailContinuationLine(leftText) { continue }
            merchantRows.append(leftText)
        }

        let removable = (dateMatch.originalText.map { [$0] } ?? []) + amountObservations.map(\.text)
        var merchant = heuristics.cleanMerchantDescription(
            from: merchantRows.joined(separator: " "),
            removing: removable
        )

        // Field-pattern guard: a value that is itself just a date ("Sep 2",
        // "09/02", "Today") is never the merchant — leave it blank for review.
        if !merchant.isEmpty, heuristics.isEssentiallyJustADate(merchant) {
            merchant = ""
            flags.insert(.possibleNonTransactionLine)
        }

        if merchant.isEmpty { flags.insert(.missingMerchantDescription) }
        confidence.merchantDescription = merchant.isEmpty ? 0 : (merchantRows.count > 1 ? 0.78 : 0.85)

        // MARK: Classify the region
        let hasAmount = amount != nil || flags.contains(.multipleAmounts)

        // A row that is only a date is a section header, not a transaction.
        if !hasAmount, merchant.isEmpty, let headerDate = dateMatch.date {
            return .sectionHeader(headerDate)
        }

        // Card balances ("VISA / CAD 334.34"), currency-code rows, chrome: an
        // amount with no real merchant is not a transaction.
        if heuristics.isNonMerchantText(merchant) {
            return .ignored
        }
        // A region needs an amount or its own date to be a useful candidate.
        // A carried section date alone is not enough — that would let nav labels
        // ("Home  Accounts  Move Money") through.
        guard hasAmount || dateMatch.date != nil else {
            return .ignored
        }

        let candidate = TransactionCandidate(
            detectedDate: effectiveDate,
            rawMerchantDescription: merchant,
            amount: amount,
            status: status,
            originalOCRText: originalOCRText,
            sourceText: region.text,
            confidence: confidence,
            validationFlags: flags,
            observations: observations.map { $0.candidateObservation() }
        )
        return .candidate(candidate)
    }

    // MARK: Geometry

    private func isRightAligned(_ observation: OCRTextObservation, in bounds: CGRect) -> Bool {
        guard bounds.width > 0 else { return false }
        let centerFraction = centerXFraction(observation, in: bounds)
        let rightEdgeFraction = (observation.frame.maxX - bounds.minX) / bounds.width
        return centerFraction >= configuration.rightHalfThreshold
            || rightEdgeFraction >= 1 - configuration.rightEdgeSlack
    }

    private func centerXFraction(_ observation: OCRTextObservation, in bounds: CGRect) -> CGFloat {
        guard bounds.width > 0 else { return 0 }
        return (observation.centerX - bounds.minX) / bounds.width
    }
}
