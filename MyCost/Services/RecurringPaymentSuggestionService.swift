import Foundation

struct RecurringPaymentSuggestion: Identifiable, Equatable {
    let id = UUID()
    let accountName: String
    let merchantName: String
    let expectedAmount: Decimal
    let frequency: RecurrenceFrequency
    let customIntervalDays: Int
    let nextExpectedDate: Date?
    let confidence: Double
    let transactionIDs: [UUID]
    let reason: String
}

struct RecurringPaymentSuggestionService {
    private let calendar: Calendar

    init(calendar: Calendar = Calendar(identifier: .gregorian)) {
        self.calendar = calendar
    }

    func suggestions(from transactions: [Transaction]) -> [RecurringPaymentSuggestion] {
        let included = transactions
            .filter { !$0.isExcluded && $0.status == .posted }
            .sorted { $0.transactionDate < $1.transactionDate }

        let groups = Dictionary(grouping: included) { transaction in
            "\(transaction.accountName.lowercased())|\(MerchantRuleNormalizer.normalizedMerchantKey(for: transaction.originalDescription))"
        }

        return groups.values
            .compactMap(suggestion)
            .sorted { $0.confidence > $1.confidence }
    }

    func expectedMonthlyAmount(for recurringPayment: RecurringPayment) -> Decimal {
        recurringPayment.expectedAmount * Decimal(monthlyMultiplier(
            frequency: recurringPayment.frequency,
            customIntervalDays: recurringPayment.customIntervalDays
        ))
    }

    func nextExpectedDate(after date: Date, frequency: RecurrenceFrequency, customIntervalDays: Int = 30) -> Date? {
        switch frequency {
        case .none:
            nil
        case .weekly:
            calendar.date(byAdding: .day, value: 7, to: date)
        case .biweekly:
            calendar.date(byAdding: .day, value: 14, to: date)
        case .monthly:
            calendar.date(byAdding: .month, value: 1, to: date)
        case .quarterly:
            calendar.date(byAdding: .month, value: 3, to: date)
        case .yearly:
            calendar.date(byAdding: .year, value: 1, to: date)
        case .custom:
            calendar.date(byAdding: .day, value: max(1, customIntervalDays), to: date)
        }
    }

    private func suggestion(from transactions: [Transaction]) -> RecurringPaymentSuggestion? {
        guard transactions.count >= 2 else { return nil }

        let sorted = transactions.sorted { $0.transactionDate < $1.transactionDate }
        let intervals = dayIntervals(for: sorted)
        guard !intervals.isEmpty else { return nil }

        guard let intervalMatch = bestIntervalMatch(intervals: intervals, transactionCount: sorted.count) else {
            return nil
        }

        let amounts = sorted.map(\.amount)
        let averageAmount = average(amounts)
        let amountVariance = relativeAmountSpread(amounts, average: averageAmount)
        guard amountVariance <= 0.45 else { return nil }

        let intervalConsistency = intervalMatch.consistency
        let amountConsistency = max(0, 1 - Double(truncating: NSDecimalNumber(decimal: amountVariance)))
        let countScore = min(1, Double(sorted.count) / 5)
        let confidence = (intervalConsistency * 0.55) + (amountConsistency * 0.30) + (countScore * 0.15)
        guard confidence >= 0.58 else { return nil }

        guard !looksLikeHighFrequencyIncidental(sorted, intervalMatch: intervalMatch, amountVariance: amountVariance) else {
            return nil
        }

        return RecurringPaymentSuggestion(
            accountName: sorted[0].accountName,
            merchantName: sorted[0].merchantName,
            expectedAmount: averageAmount,
            frequency: intervalMatch.frequency,
            customIntervalDays: intervalMatch.customIntervalDays,
            nextExpectedDate: nextExpectedDate(
                after: sorted.last?.transactionDate ?? .now,
                frequency: intervalMatch.frequency,
                customIntervalDays: intervalMatch.customIntervalDays
            ),
            confidence: min(confidence, 0.98),
            transactionIDs: sorted.map(\.id),
            reason: "\(sorted.count) transactions about every \(intervalMatch.customIntervalDays) days"
        )
    }

    private func dayIntervals(for transactions: [Transaction]) -> [Int] {
        zip(transactions, transactions.dropFirst()).compactMap { previous, next in
            calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: previous.transactionDate),
                to: calendar.startOfDay(for: next.transactionDate)
            ).day
        }
    }

    private func bestIntervalMatch(intervals: [Int], transactionCount: Int) -> IntervalMatch? {
        let candidates: [(RecurrenceFrequency, Int, Int)] = [
            (.weekly, 7, 2),
            (.biweekly, 14, 3),
            (.monthly, 30, 6),
            (.quarterly, 91, 10),
            (.yearly, 365, 21)
        ]

        let matches = candidates.compactMap { frequency, targetDays, tolerance -> IntervalMatch? in
            let matchedIntervals = intervals.filter { interval in
                if frequency == .monthly {
                    return isMonthlyInterval(interval, tolerance: tolerance)
                }
                return abs(interval - targetDays) <= tolerance
            }
            let matchedMissedIntervals = intervals.filter { interval in
                frequency == .monthly && [2, 3].contains { multiple in
                    abs(interval - (targetDays * multiple)) <= tolerance * multiple
                }
            }
            let matchedCount = matchedIntervals.count + matchedMissedIntervals.count
            let consistency = Double(matchedCount) / Double(intervals.count)

            guard consistency >= 0.67 else { return nil }
            if frequency == .yearly, transactionCount < 2 { return nil }
            return IntervalMatch(
                frequency: frequency,
                customIntervalDays: targetDays,
                consistency: consistency
            )
        }

        if let best = matches.sorted(by: { $0.consistency > $1.consistency }).first {
            return best
        }

        guard transactionCount >= 3 else { return nil }
        let averageInterval = Int((Double(intervals.reduce(0, +)) / Double(intervals.count)).rounded())
        let spread = intervals.map { abs($0 - averageInterval) }.max() ?? 0
        guard averageInterval >= 5, spread <= max(2, averageInterval / 10) else { return nil }

        return IntervalMatch(
            frequency: .custom,
            customIntervalDays: averageInterval,
            consistency: 1 - (Double(spread) / Double(max(averageInterval, 1)))
        )
    }

    private func isMonthlyInterval(_ interval: Int, tolerance: Int) -> Bool {
        (28...31).contains(interval) || abs(interval - 30) <= tolerance
    }

    private func average(_ amounts: [Decimal]) -> Decimal {
        guard !amounts.isEmpty else { return 0 }
        return amounts.reduce(Decimal.zero, +) / Decimal(amounts.count)
    }

    private func relativeAmountSpread(_ amounts: [Decimal], average: Decimal) -> Decimal {
        guard average != 0 else { return 1 }
        let absoluteAverage = abs(average)
        let maxDifference = amounts
            .map { abs($0 - average) }
            .max() ?? 0
        return maxDifference / absoluteAverage
    }

    private func monthlyMultiplier(frequency: RecurrenceFrequency, customIntervalDays: Int) -> Double {
        switch frequency {
        case .none:
            0
        case .weekly:
            52.0 / 12.0
        case .biweekly:
            26.0 / 12.0
        case .monthly:
            1
        case .quarterly:
            1.0 / 3.0
        case .yearly:
            1.0 / 12.0
        case .custom:
            30.4375 / Double(max(1, customIntervalDays))
        }
    }

    private func looksLikeHighFrequencyIncidental(
        _ transactions: [Transaction],
        intervalMatch: IntervalMatch,
        amountVariance: Decimal
    ) -> Bool {
        guard intervalMatch.frequency == .weekly || intervalMatch.frequency == .custom else { return false }
        guard transactions.count >= 6 else { return false }
        return amountVariance > 0.20
    }
}

private struct IntervalMatch {
    let frequency: RecurrenceFrequency
    let customIntervalDays: Int
    let consistency: Double
}
